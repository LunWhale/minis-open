package nethub

import (
	"errors"
	"strings"
	"testing"
)

func (c *captureLog) count(sub string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := 0
	for _, l := range c.lines {
		if strings.Contains(l, sub) {
			n++
		}
	}
	return n
}

// [FIX-261019-30] One alert after AlertAfter consecutive path failures, one
// recovery line on the next success, nothing for failures that are not the
// path's fault.
func TestExitAlertStreaks(t *testing.T) {
	logs := &captureLog{}
	h := New(nil, logs.logf)
	up := &Upstream{ID: "p-1", Name: "Office proxy"}
	proxyD := Decision{Kind: "proxy", Upstream: up}
	tsD := Decision{Kind: "tailscale"}
	refused := &StageError{Stage: "proxy-connect", Class: ClassRefused, Err: errors.New("dial tcp 10.0.0.2:8080: connect: connection refused")}

	for i := 0; i < AlertAfter-1; i++ {
		h.recordExit(proxyD, refused)
	}
	if logs.count("[Net][Alert]") != 0 {
		t.Fatalf("alerted before %d failures", AlertAfter)
	}
	h.recordExit(proxyD, refused)
	line := logs.find("[Net][Alert]")
	for _, want := range []string{"exit=proxy id=p-1 ", "failures=3", "stage=proxy-connect", "class=refused", "name=Office_proxy", "err=dial tcp"} {
		if !strings.Contains(line, want) {
			t.Fatalf("alert %q lacks %q", line, want)
		}
	}
	for i := 0; i < 5; i++ {
		h.recordExit(proxyD, refused)
	}
	if n := logs.count("[Net][Alert]"); n != 1 {
		t.Fatalf("one alert per streak, got %d", n)
	}

	h.recordExit(proxyD, nil)
	if logs.find("[Net][Recovered] exit=proxy id=p-1") == "" {
		t.Fatal("no recovery line after success")
	}
	h.recordExit(proxyD, nil)
	if n := logs.count("[Net][Recovered]"); n != 1 {
		t.Fatalf("recovery logged %d times", n)
	}

	// The proxy works but cannot reach the target: not the proxy's fault.
	target := &StageError{Stage: "proxy-target", Class: ClassProxyReject, Err: errors.New("proxy CONNECT x:443: 502")}
	for i := 0; i < 5; i++ {
		h.recordExit(proxyD, target)
	}
	// Direct dials never count.
	direct := &StageError{Stage: "direct", Class: ClassRefused, Err: errors.New("refused")}
	for i := 0; i < 5; i++ {
		h.recordExit(Decision{Kind: "direct"}, direct)
	}
	if n := logs.count("[Net][Alert]"); n != 1 {
		t.Fatalf("proxy-target / direct failures alerted (%d alerts)", n)
	}

	// A success in between breaks the streak.
	tsErr := &StageError{Stage: "tailnet", Class: ClassTimeout, Err: errors.New("i/o timeout")}
	h.recordExit(tsD, tsErr)
	h.recordExit(tsD, tsErr)
	h.recordExit(tsD, nil)
	h.recordExit(tsD, tsErr)
	h.recordExit(tsD, tsErr)
	if logs.find("exit=tailscale failures") != "" {
		t.Fatal("streak survived a success")
	}
	h.recordExit(tsD, tsErr)
	if !strings.Contains(logs.find("[Net][Alert] exit=tailscale"), "failures=3 stage=tailnet class=timeout err=i/o timeout") {
		t.Fatalf("tailscale alert: %q", logs.find("[Net][Alert] exit=tailscale"))
	}

	// A changed config clears streaks; an identical one keeps them.
	h.recordExit(proxyD, refused)
	h.recordExit(proxyD, refused)
	h.Configure(Config{DefaultRoute: "direct"})
	h.Configure(Config{DefaultRoute: "direct"})
	h.recordExit(proxyD, refused)
	if n := logs.count("[Net][Alert] exit=proxy"); n != 1 {
		t.Fatalf("streak survived a config change (%d proxy alerts)", n)
	}
	h.recordExit(proxyD, refused)
	h.Configure(Config{DefaultRoute: "direct"})
	h.recordExit(proxyD, refused)
	if n := logs.count("[Net][Alert] exit=proxy"); n != 2 {
		t.Fatalf("an unchanged config reset the streak (%d proxy alerts)", n)
	}
}

func TestExitAlertFieldsStayOnOneLine(t *testing.T) {
	logs := &captureLog{}
	h := New(nil, logs.logf)
	d := Decision{Kind: "proxy", Upstream: &Upstream{ID: "a b=c", Name: "x\ny"}}
	e := &StageError{Stage: "proxy-handshake", Class: ClassOther, Err: errors.New("line1\nline2 " + strings.Repeat("z", 300))}
	for i := 0; i < AlertAfter; i++ {
		h.recordExit(d, e)
	}
	l := logs.find("[Net][Alert]")
	if strings.Contains(l, "\n") || !strings.Contains(l, "id=a_b_c ") || !strings.Contains(l, "name=x_y ") || !strings.HasSuffix(l, "…") {
		t.Fatalf("bad alert line %q", l)
	}
}
