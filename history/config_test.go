package main

import (
	"os"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestParseModeAcceptsOnlyKnownModes(t *testing.T) {
	for _, value := range []string{"rabbitmq", "postgres"} {
		if mode, err := parseMode(value); err != nil || mode != value {
			t.Errorf("parseMode(%q) = %q, %v; очікувався %q без помилки", value, mode, err, value)
		}
	}
	for _, value := range []string{"", "RabbitMQ", "postgresql", "redis", " postgres"} {
		_, err := parseMode(value)
		if err == nil {
			t.Errorf("parseMode(%q): очікувалась помилка", value)
			continue
		}
		if !strings.Contains(err.Error(), "APP_MODE") {
			t.Errorf("parseMode(%q): помилка без назви змінної: %v", value, err)
		}
	}
}

func TestParseDurationAcceptsPositiveDuration(t *testing.T) {
	duration, err := parseDuration("QUEUE_POLL_INTERVAL", "5s")
	if err != nil || duration != 5*time.Second {
		t.Fatalf("parseDuration(5s) = %v, %v; очікувалось 5s", duration, err)
	}
}

func TestParseDurationRejectsWrongValues(t *testing.T) {
	// "5" without a unit is also wrong: it is not clear whether it is seconds or minutes.
	for _, value := range []string{"", "0s", "-5s", "5", "five seconds"} {
		_, err := parseDuration("QUEUE_POLL_INTERVAL", value)
		if err == nil {
			t.Errorf("parseDuration(%q): очікувалась помилка", value)
			continue
		}
		if !strings.Contains(err.Error(), "QUEUE_POLL_INTERVAL") {
			t.Errorf("parseDuration(%q): помилка без назви змінної: %v", value, err)
		}
	}
}

func TestUSR1StopsRequests(t *testing.T) {
	stopped := stopRequestsOnSignal()
	if stopped.Load() {
		t.Fatal("запити зупинені ще до сигналу")
	}

	// The test sends USR1 to its own process, as docker kill --signal USR1 does to History.
	if err := syscall.Kill(os.Getpid(), syscall.SIGUSR1); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for !stopped.Load() {
		if time.Now().After(deadline) {
			t.Fatal("за 2 с після USR1 запити не зупинились")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
