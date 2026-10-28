package nethub

import (
	"strings"
	"testing"
	"time"
)

// The diagnose check of the HTTP front: passes while it listens, fails with
// a "not listening" error once it stops, and never echoes the password.
func TestHTTPSelfTest(t *testing.T) {
	h := New(newFake(), nil)
	h.Configure(Config{DefaultRoute: "direct"})
	if _, err := h.HTTPSelfTest(time.Second); err == nil {
		t.Fatal("self-test passed with no entry at all")
	}
	_, pass, err := h.Start(0)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Stop()
	if _, err := h.HTTPSelfTest(time.Second); err == nil || !strings.Contains(err.Error(), "not listening") {
		t.Fatalf("front not started: want a not-listening error, got %v", err)
	}
	if _, err := h.StartHTTP(0); err != nil {
		t.Fatal(err)
	}
	if _, err := h.HTTPSelfTest(2 * time.Second); err != nil {
		t.Fatalf("self-test through a listening front: %v", err)
	}
	h.StopHTTP()
	_, err = h.HTTPSelfTest(time.Second)
	if err == nil {
		t.Fatal("self-test passed after StopHTTP")
	}
	if strings.Contains(err.Error(), pass) {
		t.Fatal("self-test error carries the entry password")
	}
}
