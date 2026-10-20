package model

import "time"

type BarsResponse struct {
	Symbol   string `json:"symbol"`
	Interval string `json:"interval"`
	Bars     []Bar  `json:"bars"`
}

type Bar struct {
	OpenTime   time.Time `json:"openTime"`
	Open       float64   `json:"open"`
	High       float64   `json:"high"`
	Low        float64   `json:"low"`
	Close      float64   `json:"close"`
	Volume     float64   `json:"volume"`
	TickVolume int64     `json:"tickVolume"`
	IsOpen     bool      `json:"isOpen"`
}

/*
{
  "symbol": "EURUSD",
  "interval": "1h",
  "bars": [
    {
      "openTime": "2026-02-24T13:00:00Z",
      "open": 1.08521,
      "high": 1.08574,
      "low": 1.08498,
      "close": 1.08542,
      "volume": 0,
      "tickVolume": 340,
      "isOpen": true
    },
    {
      "openTime": "2026-02-24T12:00:00Z",
      "open": 1.08480,
      "high": 1.08530,
      "low": 1.08440,
      "close": 1.08521,
      "volume": 0,
      "tickVolume": 412,
      "isOpen": false
    }
  ]
}
*/
