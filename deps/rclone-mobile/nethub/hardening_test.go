package nethub

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// Second-round hardening: the entry recovers from a dead listener, failures
// name their stage and class, self-test works, and a slow or broken tailnet
// never slows non-tailnet traffic.

type captureLog struct {
	mu    sync.Mutex
	lines []string
}

func (c *captureLog) logf(format string, a ...any) {
	c.mu.Lock()
	c.lines = append(c.lines, fmt.Sprintf(format, a...))
	c.mu.Unlock()
}

func (c *captureLog) find(sub string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, l := range c.lines {
		if strings.Contains(l, sub) {
			return l
		}
	}
	return ""
}

func TestListenerDeathIsDetectedAndRestartable(t *testing.T) {
	logs := &captureLog{}
	h := New(nil, logs.logf)
	h.Configure(Config{DefaultRoute: "direct"})
	addr1, _, err := h.Start(0)
	if err != nil || !h.Alive() {
		t.Fatalf("start: %v alive=%v", err, h.Alive())
	}
	// Simulate iOS reclaiming the socket: close the listener behind the hub's back.
	h.mu.RLock()
	ln := h.ln
	h.mu.RUnlock()
	ln.Close()
	deadline := time.Now().Add(2 * time.Second)
	for h.Alive() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if h.Alive() {
		t.Fatal("a closed listener must make Alive() false")
	}
	if logs.find("[Net][Entry]") == "" {
		t.Fatal("listener death must be logged under [Net][Entry]")
	}
	addr2, pass2, err := h.Start(0)
	if err != nil || addr2 == "" || pass2 == "" || !h.Alive() {
		t.Fatalf("restart: %v %q", err, addr2)
	}
	_ = addr1
	if _, err := h.SelfTest(2 * time.Second); err != nil {
		t.Fatalf("self-test after restart: %v", err)
	}
	h.Stop()
	if _, err := h.SelfTest(time.Second); Stage(err) != "entry" {
		t.Fatalf("self-test of a stopped entry must fail at stage entry, got %v", err)
	}
}

func TestFailureStagesAndClasses(t *testing.T) {
	// A port nobody listens on.
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	dead := l.Addr().String()
	l.Close()
	host, ps, _ := net.SplitHostPort(dead)
	port, _ := strconv.Atoi(ps)

	_, err := DialUpstream(context.Background(), &net.Dialer{Timeout: time.Second},
		Upstream{Type: "http", Host: host, Port: port}, "example.com:443")
	if Stage(err) != "proxy-connect" || Classify(err) != ClassRefused {
		t.Fatalf("unreachable proxy: stage=%q class=%q (%v)", Stage(err), Classify(err), err)
	}

	httpAddr, _ := httpConnectProxy(t) // requires user:pw
	hh, hp, _ := net.SplitHostPort(httpAddr)
	hpi, _ := strconv.Atoi(hp)
	_, err = DialUpstream(context.Background(), &net.Dialer{Timeout: time.Second},
		Upstream{Type: "http", Host: hh, Port: hpi, Username: "user", Password: "bad"}, "example.com:443")
	if Stage(err) != "proxy-handshake" || Classify(err) != ClassProxyAuth {
		t.Fatalf("wrong proxy password: stage=%q class=%q (%v)", Stage(err), Classify(err), err)
	}
	_, err = DialUpstream(context.Background(), &net.Dialer{Timeout: time.Second},
		Upstream{Type: "http", Host: hh, Port: hpi, Username: "user", Password: "pw"}, dead)
	if Stage(err) != "proxy-target" || Classify(err) != ClassProxyReject {
		t.Fatalf("target unreachable behind proxy: stage=%q class=%q (%v)", Stage(err), Classify(err), err)
	}

	// SOCKS5 upstream (another hub): wrong password vs unreachable target.
	up := New(nil, nil)
	up.Configure(Config{DefaultRoute: "direct"})
	upAddr, upPass, _ := up.Start(0)
	defer up.Stop()
	uh, ups, _ := net.SplitHostPort(upAddr)
	upi, _ := strconv.Atoi(ups)
	_, err = DialUpstream(context.Background(), &net.Dialer{Timeout: time.Second},
		Upstream{Type: "socks5", Host: uh, Port: upi, Username: "x", Password: "wrong"}, "example.com:443")
	if Stage(err) != "proxy-handshake" || Classify(err) != ClassProxyAuth {
		t.Fatalf("socks wrong password: stage=%q class=%q (%v)", Stage(err), Classify(err), err)
	}
	_, err = DialUpstream(context.Background(), &net.Dialer{Timeout: time.Second},
		Upstream{Type: "socks5", Host: uh, Port: upi, Username: "x", Password: upPass}, dead)
	if Stage(err) != "proxy-target" {
		t.Fatalf("socks target refused: stage=%q class=%q (%v)", Stage(err), Classify(err), err)
	}
}

func TestEntryLogsStageOnFailure(t *testing.T) {
	logs := &captureLog{}
	h := New(newFake(), logs.logf)
	h.Configure(Config{DefaultRoute: "proxy:p", Upstreams: []Upstream{{ID: "p", Name: "Office", Type: "http", Host: "127.0.0.1", Port: 1}}})
	addr, pass, _ := h.Start(0)
	defer h.Stop()
	if _, err := roundTrip(t, addr, "shell", pass, "example.com:443"); err == nil {
		t.Fatal("dead upstream must fail")
	}
	line := logs.find("[Net][Proxy]")
	for _, want := range []string{"FAIL", "stage=proxy-connect", "via=proxy:Office", "class=refused", "tag=shell"} {
		if !strings.Contains(line, want) {
			t.Fatalf("proxy failure line %q lacks %q", line, want)
		}
	}
	if p := logs.find("[Net][Policy]"); !strings.Contains(p, "exit=proxy:Office") || strings.Contains(p, pass) {
		t.Fatalf("policy line wrong or leaks the password: %q", p)
	}
	if _, err := roundTrip(t, addr, "shell", "bad-password", "example.com:443"); err == nil {
		t.Fatal("wrong entry password must be refused")
	}
	if logs.find("rejected: wrong entry password") == "" {
		t.Fatal("entry auth failure must be logged")
	}
}

// slowTailnet blocks in Running(); the hub must still serve non-tailnet
// destinations promptly when Tailscale is off in settings, and a broken
// tailnet must not break the user's proxy / direct routes.
type brokenTailnet struct{ fakeTailnet }

func (b *brokenTailnet) Running() bool { return false } // NeedsLogin / failed start
func (b *brokenTailnet) Dial(ctx context.Context, n, a string) (net.Conn, error) {
	return nil, errors.New("tsnet: not started")
}

func TestBrokenTailnetDoesNotAffectOtherTraffic(t *testing.T) {
	direct := echoServer(t, "direct:")
	b := &brokenTailnet{}
	b.prefixes = []netip.Prefix{netip.MustParsePrefix("100.64.0.0/10")}
	h := New(b, nil)
	h.Configure(Config{DefaultRoute: "direct", Tailscale: true})
	addr, pass, _ := h.Start(0)
	defer h.Stop()
	if got, err := roundTrip(t, addr, "default", pass, direct); err != nil || got != "direct:ping\n" {
		t.Fatalf("direct traffic with a broken tailnet: %q %v", got, err)
	}
	if d := h.Decide("default", "100.70.0.1"); d.Kind != "direct" {
		t.Fatalf("tailnet down: a tailnet address follows the route, got %s", d.Kind)
	}
	_ = io.Discard
}
