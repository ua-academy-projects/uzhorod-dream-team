package client

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"
)

type Value struct {
	Value     float64   `json:"value"`
	Timestamp time.Time `json:"timestamp"`
}

type CoinGeckoResponse struct {
	Bitcoin struct {
		USD float64 `json:"usd"`
	} `json:"bitcoin"`
	Ethereum struct {
		USD float64 `json:"usd"`
	} `json:"ethereum"`
}

type CoinbaseResponse struct {
	Data struct {
		Amount string `json:"amount"`
	} `json:"data"`
}

func Parse(body []byte) (float64, error) {
	var response CoinGeckoResponse
	if err := json.Unmarshal(body, &response); err != nil {
		return 0, fmt.Errorf("decode external response: %w", err)
	}
	if response.Bitcoin.USD > 0 {
		return response.Bitcoin.USD, nil
	}
	if response.Ethereum.USD > 0 {
		return response.Ethereum.USD, nil
	}
	var coinbase CoinbaseResponse
	if err := json.Unmarshal(body, &coinbase); err != nil {
		return 0, fmt.Errorf("decode external response: %w", err)
	}
	value, err := strconv.ParseFloat(coinbase.Data.Amount, 64)
	if err != nil || value <= 0 {
		return 0, fmt.Errorf("response contains no positive USD price")
	}
	return value, nil
}

type External struct {
	URL  string
	HTTP *http.Client
}

func (e External) Fetch(ctx context.Context) (Value, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, e.URL, nil)
	if err != nil {
		return Value{}, err
	}
	response, err := e.HTTP.Do(request)
	if err != nil {
		return Value{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return Value{}, fmt.Errorf("external API returned status %s", response.Status)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return Value{}, err
	}
	value, err := Parse(body)
	if err != nil {
		return Value{}, err
	}
	return Value{Value: value, Timestamp: time.Now().UTC()}, nil
}
