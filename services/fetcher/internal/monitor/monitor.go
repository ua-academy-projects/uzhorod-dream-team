package monitor

import (
	"context"
	"time"
)

func Ticker(ctx context.Context, interval time.Duration, fn func()) {
	for {
		now := time.Now()

		next := now.Truncate(interval).Add(interval + 7*time.Second)

		// log.Printf("now=%s next=%s",
		// 	now.Format("15:04:05.000"),
		// 	next.Format("15:04:05.000"),
		// )

		timer := time.NewTimer(time.Until(next))

		select {
		case <-ctx.Done():
			timer.Stop()
			return

		case <-timer.C:
			// log.Printf("TICK: %s", time.Now().Format("15:04:05.000"))
			fn()
		}
	}
}
