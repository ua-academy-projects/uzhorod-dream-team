package app

import (
	"context"
	"log"
	"time"
)

func RunScheduler(ctx context.Context, collector *Collector, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if ctx.Err() != nil {
				return
			}
			job, err := collector.Collect(ctx)
			if err != nil {
				log.Print("scheduled collection could not be queued")
				continue
			}
			log.Printf("scheduled collection queued request_id=%s", job.RequestID)
		}
	}
}
