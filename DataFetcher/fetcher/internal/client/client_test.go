package client

import "testing"

func TestParse(t *testing.T) {
	got, err := Parse([]byte(`{"bitcoin":{"usd":123.45}}`))
	if err != nil || got != 123.45 {
		t.Fatalf("got %v, %v", got, err)
	}
}

func TestParseCoinbase(t *testing.T) {
	got, err := Parse([]byte(`{"data":{"base":"BTC","currency":"USD","amount":"83065.995"}}`))
	if err != nil || got != 83065.995 {
		t.Fatalf("got %v, %v", got, err)
	}
}
func TestParseInvalid(t *testing.T) {
	if _, err := Parse([]byte(`{}`)); err == nil {
		t.Fatal("expected missing value error")
	}
}
