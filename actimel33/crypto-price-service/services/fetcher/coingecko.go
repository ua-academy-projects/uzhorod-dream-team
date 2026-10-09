package main

import (
	"fmt"
	"math"
	"net/url"
	"time"
)

type coinGecko struct {
	baseURL string
	http    *retryClient
}

func newCoinGecko(baseURL string, client *retryClient) PriceSource {
	return &coinGecko{baseURL: baseURL, http: client}
}

func (c *coinGecko) Name() string { return "coingecko" }

// Mind the time units — they are easy to mix up:
//
//	/simple/price  -> last_updated_at is in SECONDS
//	/market_chart  -> timestamps are in MILLISECONDS
func (c *coinGecko) Quote(coin, vs string) (PricePoint, error) {
	endpoint := fmt.Sprintf(
		"%s/simple/price?ids=%s&vs_currencies=%s&include_last_updated_at=true",
		c.baseURL, url.QueryEscape(coin), url.QueryEscape(vs),
	)

	var payload map[string]map[string]float64
	if err := c.http.getJSON(endpoint, &payload); err != nil {
		return PricePoint{}, err
	}

	// Unknown coin: CoinGecko answers 200 with an empty object rather than an error.
	entry, ok := payload[coin]
	if !ok {
		return PricePoint{}, &ErrUnknownAsset{Coin: coin, Vs: vs}
	}
	price, ok := entry[vs]
	if !ok {
		return PricePoint{}, &ErrUnknownAsset{Coin: coin, Vs: vs}
	}

	seconds := int64(entry["last_updated_at"])
	if seconds == 0 {
		seconds = time.Now().Unix()
	}
	return PricePoint{Price: price, ObservedAt: time.Unix(seconds, 0).UTC()}, nil
}

func (c *coinGecko) Chart(coin, vs string, days int) ([]PricePoint, error) {
	endpoint := fmt.Sprintf(
		"%s/coins/%s/market_chart?vs_currency=%s&days=%d",
		c.baseURL, url.PathEscape(coin), url.QueryEscape(vs), days,
	)

	var payload struct {
		Prices [][2]float64 `json:"prices"`
	}
	if err := c.http.getJSON(endpoint, &payload); err != nil {
		return nil, err
	}
	if payload.Prices == nil {
		return nil, fmt.Errorf("unexpected market_chart payload")
	}

	points := make([]PricePoint, 0, len(payload.Prices))
	for _, pair := range payload.Prices {
		millis, price := pair[0], pair[1]
		if math.IsNaN(millis) || math.IsNaN(price) || math.IsInf(price, 0) {
			continue
		}
		points = append(points, PricePoint{
			Price:      price,
			ObservedAt: time.UnixMilli(int64(millis)).UTC(),
		})
	}
	return points, nil
}
