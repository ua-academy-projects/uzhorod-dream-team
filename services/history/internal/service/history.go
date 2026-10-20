package service

import (
	"context"
	"encoding/json"
	"fmt"
	"history/internal/model"
	"history/internal/repository/history"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

type HistoryService struct {
	repo history.Repository

	fetcherHost string
	fetcherPort string
}

func NewHistoryService(
	repo history.Repository,
) *HistoryService {
	fetcherHost := os.Getenv("FETCHER_HOST")
	fetcherPort := os.Getenv("FETCHER_PORT")

	return &HistoryService{
		repo: repo,

		fetcherHost: fetcherHost,
		fetcherPort: fetcherPort,
	}
}

func (s *HistoryService) GetHistory(
	ctx context.Context,
	symbol string,
	date time.Time,
) ([]model.Bar, error) {
	return s.repo.GetHistory(ctx, symbol, date)
}

func (s *HistoryService) GetLast(
	ctx context.Context,
	symbol string,
) ([]model.Bar, error) {
	return s.repo.GetLast(ctx, symbol)
}

func (s *HistoryService) SaveBars(
	ctx context.Context,
	symbol string,
	bars []model.Bar,
) error {
	return s.repo.SaveBars(ctx, symbol, bars)
}

func (s *HistoryService) FetchInitialBars(
	ctx context.Context,
	from time.Time,
	to time.Time,
) (time.Time, error) {
	var last time.Time

	for from.Before(to) {
		minutes := int(to.Sub(from).Minutes())

		if minutes <= 0 {
			break
		}

		limit := minutes

		if limit > 1000 {
			limit = 1000
		}

		nextTo := from.Add(time.Duration(limit) * time.Minute)

		if nextTo.After(to) {
			nextTo = to
		}

		url := fmt.Sprintf(
			"http://%s:%s/api/fetcher?from=%s&to=%s&limit=%d",
			s.fetcherHost,
			s.fetcherPort,
			from.UTC().Format(time.RFC3339),
			nextTo.UTC().Format(time.RFC3339),
			limit,
		)

		req, err := http.NewRequestWithContext(
			ctx,
			http.MethodGet,
			url,
			nil,
		)
		if err != nil {
			return time.Time{}, err
		}

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return time.Time{}, err
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			return time.Time{}, fmt.Errorf("fetcher returned status %d", resp.StatusCode)
		}

		var barsResp model.BarsResponse
		if err := json.NewDecoder(resp.Body).Decode(&barsResp); err != nil {
			return time.Time{}, err
		}

		if err := s.SaveBars(ctx, barsResp.Symbol, barsResp.Bars); err != nil {
			return time.Time{}, err
		}

		for _, bar := range barsResp.Bars {
			if bar.OpenTime.After(last) {
				last = bar.OpenTime
			}
		}

		from = nextTo
	}

	return last, nil
}

func (s *HistoryService) FetchCurrentBars(
	ctx context.Context,
) error {
	url := fmt.Sprintf(
		"http://%s:%s/api/fetcher",
		s.fetcherHost,
		s.fetcherPort,
	)

	req, err := http.NewRequestWithContext(
		ctx,
		http.MethodGet,
		url,
		nil,
	)
	if err != nil {
		return err
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Printf("failed to fetch data: %v", err)
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("fetcher returned status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Printf("failed to read response body: %v", err)
		return err
	}

	var barsResp model.BarsResponse

	err = json.Unmarshal(body, &barsResp)
	if err != nil {
		log.Printf("failed to unmarshal JSON: %v", err)
		return err
	}

	return s.SaveBars(ctx, barsResp.Symbol, barsResp.Bars)
}

func (s *HistoryService) GetLastOpenTime(
	ctx context.Context,
	symbol string,
) (*time.Time, error) {
	return s.repo.GetLastOpenTime(ctx, symbol)
}
