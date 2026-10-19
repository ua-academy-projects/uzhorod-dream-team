package main

import (
	"context"
	"log"
	"time"
)

type temperatureRange struct {
	Start time.Time `json:"start"`
	End   time.Time `json:"end"`
}

// Recheck the latest day for model corrections and fill older missing blocks.
func temperatureRanges(start, end time.Time, missing []time.Time) []temperatureRange {
	recent := end.Add(-24 * time.Hour)
	if recent.Before(start) {
		recent = start
	}
	var ranges []temperatureRange
	for _, hour := range missing {
		if !hour.Before(recent) {
			break
		}
		if len(ranges) > 0 && ranges[len(ranges)-1].End.Add(time.Hour).Equal(hour) {
			ranges[len(ranges)-1].End = hour
		} else {
			ranges = append(ranges, temperatureRange{hour, hour})
		}
	}
	if len(ranges) > 0 && ranges[len(ranges)-1].End.Add(time.Hour).Equal(recent) {
		ranges[len(ranges)-1].End = end
	} else {
		ranges = append(ranges, temperatureRange{recent, end})
	}
	// Bound request count if the database contains many scattered gaps.
	if len(ranges) > 4 {
		return []temperatureRange{{ranges[0].Start, end}}
	}
	return ranges
}

func runTemperatureScheduler(ctx context.Context, collector *Collector, interval time.Duration, days int) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		if ctx.Err() != nil {
			return
		}
		job, err := collector.SyncTemperature(ctx, days)
		if err != nil {
			log.Printf("temperature history sync: %v", err)
		} else {
			log.Printf("temperature history queued request_id=%s", job.RequestID)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
