// Package config reads the Fetcher configuration from environment variables
// and, if present, from a .env file in the working directory.
package config

import (
	"bufio"
	"errors"
	"io/fs"
	"os"
	"strings"
)

type Config struct {
	AMQPURL          string
	OpenMeteoBaseURL string
}

func getenv(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// LoadDotEnv reads KEY=VALUE lines from the file at path into the process environment.
// Variables that are already set are not overridden (same rule as Node's dotenv), so real
// environment variables win over the file. A missing file is not an error.
func LoadDotEnv(path string) error {
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		key, value, ok := strings.Cut(line, "=")
		key = strings.TrimSpace(key)
		if !ok || key == "" {
			continue
		}
		if _, exists := os.LookupEnv(key); !exists {
			os.Setenv(key, unquote(strings.TrimSpace(value)))
		}
	}
	return scanner.Err()
}

func unquote(v string) string {
	if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
		return v[1 : len(v)-1]
	}
	// unquoted value: strip a trailing " # comment"
	if i := strings.Index(v, " #"); i >= 0 {
		return strings.TrimSpace(v[:i])
	}
	return v
}

func Load() Config {
	return Config{
		AMQPURL:          getenv("AMQP_URL", "amqp://guest:guest@localhost:5672/"),
		OpenMeteoBaseURL: getenv("OPEN_METEO_BASE_URL", "https://api.open-meteo.com/v1/forecast"),
	}
}
