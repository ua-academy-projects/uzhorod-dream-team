package main

import "time"

// PricePoint is a price together with the moment it refers to.
type PricePoint struct {
	Price      float64
	ObservedAt time.Time
}

// PriceSource is the data source contract. Swapping CoinGecko for another API
// means a new implementation of this interface; the rest of the code stays put.
type PriceSource interface {
	Name() string
	Quote(coin, vs string) (PricePoint, error)
	Chart(coin, vs string, days int) ([]PricePoint, error)
}

// ErrUnknownAsset separates "no such pair" — a permanent state — from a network failure.
type ErrUnknownAsset struct {
	Coin string
	Vs   string
}

func (e *ErrUnknownAsset) Error() string {
	return "unknown asset: " + e.Coin + "/" + e.Vs
}
