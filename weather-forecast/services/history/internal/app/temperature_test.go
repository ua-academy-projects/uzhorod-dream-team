package app

import (
	"testing"
	"time"
)

func TestTemperatureRanges(t *testing.T) {
	end := time.Date(2026, 10, 8, 9, 0, 0, 0, time.UTC)
	start := end.Add(-30 * 24 * time.Hour)
	allHours := func(from, to time.Time) []time.Time {
		var hours []time.Time
		for hour := from; !hour.After(to); hour = hour.Add(time.Hour) {
			hours = append(hours, hour)
		}
		return hours
	}
	for _, tc := range []struct {
		name          string
		missing       []time.Time
		ranges, hours int
	}{
		{"first backfill", allHours(start, end), 1, 721},
		{"restart or regular sync", nil, 1, 25},
		{"three days offline", allHours(end.Add(-72*time.Hour), end), 1, 73},
		{"older gap", []time.Time{start.Add(time.Hour), start.Add(2 * time.Hour)}, 2, 27},
		{"many scattered gaps", []time.Time{start, start.Add(2 * time.Hour), start.Add(4 * time.Hour), start.Add(6 * time.Hour)}, 1, 721},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ranges := temperatureRanges(start, end, tc.missing)
			count := 0
			for _, r := range ranges {
				count += int(r.End.Sub(r.Start)/time.Hour) + 1
			}
			if len(ranges) != tc.ranges || count != tc.hours {
				t.Fatalf("ranges=%v hours=%d", ranges, count)
			}
		})
	}
}
