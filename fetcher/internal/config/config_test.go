package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadDotEnv(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	content := "# comment\n\nFROM_FILE=hello\nQUOTED=\"a b\"\nWITH_COMMENT=3003 # port\nALREADY_SET=from-file\nexport EXPORTED=yes\nbroken line\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ALREADY_SET", "from-env")
	// register for cleanup: LoadDotEnv sets these with os.Setenv
	for _, k := range []string{"FROM_FILE", "QUOTED", "WITH_COMMENT", "EXPORTED"} {
		t.Setenv(k, "")
		os.Unsetenv(k)
	}

	if err := LoadDotEnv(path); err != nil {
		t.Fatal(err)
	}

	want := map[string]string{
		"FROM_FILE":    "hello",
		"QUOTED":       "a b",
		"WITH_COMMENT": "3003",
		"EXPORTED":     "yes",
		"ALREADY_SET":  "from-env", // real environment wins over the file
	}
	for k, v := range want {
		if got := os.Getenv(k); got != v {
			t.Errorf("%s = %q, want %q", k, got, v)
		}
	}
}

func TestLoadDotEnvMissingFileIsNotAnError(t *testing.T) {
	if err := LoadDotEnv(filepath.Join(t.TempDir(), "nope.env")); err != nil {
		t.Fatal(err)
	}
}

func TestLoadUseRedisRabbitMQ(t *testing.T) {
	for raw, want := range map[string]bool{"": true, "true": true, "YES": true, "1": true, "false": false, " No ": false, "0": false} {
		t.Setenv("USE_REDIS_RABBITMQ", raw)
		cfg, err := Load()
		if err != nil || cfg.UseRedisRabbitMQ != want {
			t.Errorf("USE_REDIS_RABBITMQ=%q: got %v, %v; want %v", raw, cfg.UseRedisRabbitMQ, err, want)
		}
	}
	t.Setenv("USE_REDIS_RABBITMQ", "flase")
	if _, err := Load(); err == nil {
		t.Error("a typo must be an error, not the default")
	}
}
