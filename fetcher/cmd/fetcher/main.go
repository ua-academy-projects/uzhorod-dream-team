// Command fetcher runs the Fetcher service: a RabbitMQ worker that talks to Open-Meteo.
// It has no HTTP API: requests arrive on a queue and replies go back through a queue.
//
// Usage:
//
//	fetcher                    consume fetch requests from RabbitMQ (AMQP_URL)
//	fetcher --once             print the current weather for the default location and exit
//	fetcher --once --history 2 print hourly data for the last 2 days and exit
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"fetcher/internal/config"
	"fetcher/internal/openmeteo"
	"fetcher/internal/worker"
)

func main() {
	once := flag.Bool("once", false, "fetch once, print the result and exit (no HTTP server)")
	history := flag.Int("history", 0, "with --once: fetch hourly data for the last N days instead of the current weather")
	flag.Parse()

	if err := config.LoadDotEnv(".env"); err != nil {
		fmt.Fprintln(os.Stderr, "cannot read .env:", err)
		os.Exit(1)
	}
	cfg := config.Load()
	client := openmeteo.NewClient(cfg.OpenMeteoBaseURL)

	if *once {
		if err := runOnce(client, *history); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	// On a lost connection the process exits with an error and systemd restarts it
	if err := work(cfg, client); err != nil {
		slog.Error("fetcher stopped", "error", err)
		os.Exit(1)
	}
}

// defaultLocation is used only by --once; queue requests carry the location from the caller.
func defaultLocation() (openmeteo.Location, error) {
	loc := openmeteo.Location{Name: "Berlin", Latitude: 52.52, Longitude: 13.41}
	if v := os.Getenv("LOCATION_NAME"); v != "" {
		loc.Name = v
	}
	for name, target := range map[string]*float64{"LATITUDE": &loc.Latitude, "LONGITUDE": &loc.Longitude} {
		if v := os.Getenv(name); v != "" {
			n, err := strconv.ParseFloat(v, 64)
			if err != nil {
				return loc, fmt.Errorf("environment variable %s must be a number", name)
			}
			*target = n
		}
	}
	return loc, nil
}

func runOnce(client *openmeteo.Client, historyDays int) error {
	loc, err := defaultLocation()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	var result any
	if historyDays > 0 {
		observations, err := client.FetchRecentHistory(ctx, loc, historyDays)
		if err != nil {
			return err
		}
		fmt.Printf("Fetched %d hourly observations\n", len(observations))
		result = observations[max(0, len(observations)-3):]
	} else {
		if result, err = client.FetchCurrent(ctx, loc); err != nil {
			return err
		}
	}
	out, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(out))
	return nil
}

func work(cfg config.Config, client *openmeteo.Client) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return worker.Run(ctx, cfg.AMQPURL, client)
}
