package service

import (
	"context"
	"encoding/json"
	"fetcher/internal/model"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"
)

type FetcherService struct {
	symbol string
}

func NewFetcherService(symbol string) *FetcherService {
	return &FetcherService{
		symbol: symbol,
	}
}

func (s *FetcherService) Fetch(
	ctx context.Context,
	from *time.Time,
	to *time.Time,
	limit int,
) (*model.BarsResponse, error) {
	url := fmt.Sprintf(
		"https://biquote.io/api/%s/ohlc?interval=1m&limit=%d",
		s.symbol,
		limit,
	)

	if from != nil {
		url += "&from=" + from.UTC().Format(time.RFC3339)
	}
	if to != nil {
		url += "&to=" + to.UTC().Format(time.RFC3339)
	}

	req, err := http.NewRequestWithContext(
		ctx,
		http.MethodGet,
		url,
		nil,
	)
	if err != nil {
		log.Printf("failed to create request for symbol %s: %v", s.symbol, err)
		return nil, err
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Printf("failed to fetch data for symbol %s: %v", s.symbol, err)
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		log.Printf(
			"failed to fetch data for symbol %s: status code %d",
			s.symbol,
			resp.StatusCode,
		)
		return nil, fmt.Errorf(
			"unexpected status code %d for symbol %s",
			resp.StatusCode,
			s.symbol,
		)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Printf("failed to read response body for symbol %s: %v", s.symbol, err)
		return nil, err
	}

	var bars model.BarsResponse

	err = json.Unmarshal(body, &bars)
	if err != nil {
		log.Printf("failed to unmarshal JSON for symbol %s: %v", s.symbol, err)
		return nil, err
	}

	return &bars, nil
}
