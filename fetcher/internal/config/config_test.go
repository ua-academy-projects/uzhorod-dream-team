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
