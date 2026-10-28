package nethub

import (
	"bufio"
	"context"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/proxy"
)

// fakeTailnet routes its "tailnet" connections to a local echo server and
// records that it was used.
type fakeTailnet struct {
	running  bool
	exitNode bool
	prefixes []netip.Prefix
	suffix   string
	target   string // where Dial really connects
	dials    []string
}

func (f *fakeTailnet) Running() bool            { return f.running }
func (f *fakeTailnet) ExitNodeActive() bool     { return f.exitNode }
func (f *fakeTailnet) Prefixes() []netip.Prefix { return f.prefixes }
func (f *fakeTailnet) IsTailnetName(h string) bool {
	return f.suffix != "" && strings.HasSuffix(h, "."+f.suffix)
}
func (f *fakeTailnet) Dial(ctx context.Context, n, a string) (net.Conn, error) {
	f.dials = append(f.dials, a)
	var d net.Dialer
	return d.DialContext(ctx, n, f.target)
}

func newFake() *fakeTailnet {
	return &fakeTailnet{
		running: true,
		prefixes: []netip.Prefix{
			netip.MustParsePrefix("100.64.0.0/10"),
			netip.MustParsePrefix("fd7a:115c:a1e0::/48"),
			netip.MustParsePrefix("192.168.50.0/24"), // an accepted subnet route
			netip.MustParsePrefix("0.0.0.0/0"),       // exit node: must NOT make everything "tailnet"
		},
		suffix: "tail1234.ts.net",
	}
}

func TestDecideMatrix(t *testing.T) {
	ts := newFake()
	h := New(ts, nil)
	h.Configure(Config{
		DefaultRoute: "proxy:p1",
		Tags:         map[string]string{"shell": "direct", "browser": "tailscale", "prov:x": "proxy:gone", "mcp": "default"},
		Upstreams:    []Upstream{{ID: "p1", Type: "socks5", Host: "127.0.0.1", Port: 1, Bypass: []string{"*.corp.example", "10.0.0.0/8", "intranet"}}},
		Tailscale:    true,
	})
	cases := []struct{ tag, host, kind string }{
		{"default", "100.101.102.103", "tailscale"},     // tailnet IP stacks under a proxy route
		{"default", "nas.tail1234.ts.net", "tailscale"}, // MagicDNS
		{"default", "192.168.50.7", "tailscale"},        // dynamic prefix, not 100.64/10 only
		{"default", "example.com", "proxy"},
		{"default", "a.corp.example", "direct"},   // bypass suffix
		{"default", "10.2.3.4", "direct"},         // bypass CIDR
		{"default", "intranet", "direct"},         // bypass exact
		{"default", "localhost", "direct"},        // loopback always bypasses
		{"mcp", "example.com", "proxy"},           // "default" tag value follows DefaultRoute
		{"shell", "100.101.102.103", "tailscale"}, // direct still reaches the tailnet
		{"shell", "example.com", "direct"},
		{"browser", "example.com", "direct"}, // tailscale route, no exit node
		{"browser", "100.101.102.103", "tailscale"},
		{"prov:x", "example.com", "direct"},     // deleted proxy degrades to direct
		{"unknown-tag", "example.com", "proxy"}, // unknown tag = default
	}
	for _, c := range cases {
		if d := h.Decide(c.tag, c.host); d.Kind != c.kind {
			t.Errorf("Decide(%q,%q) = %s (%s), want %s", c.tag, c.host, d.Kind, d.Route, c.kind)
		}
	}
	ts.exitNode = true
	if d := h.Decide("browser", "example.com"); d.Kind != "tailscale" {
		t.Errorf("exit node: tailscale route should send everything via the tailnet, got %s", d.Kind)
	}
	if d := h.Decide("default", "example.com"); d.Kind != "proxy" {
		t.Errorf("exit node must not hijack a proxy route, got %s", d.Kind)
	}
	ts.running = false
	if d := h.Decide("default", "100.101.102.103"); d.Kind != "proxy" {
		t.Errorf("node down: tailnet IP should follow the route, got %s", d.Kind)
	}
	h.Configure(Config{DefaultRoute: "tailscale", Tailscale: false})
	ts.running = true
	if d := h.Decide("default", "100.101.102.103"); d.Kind != "direct" {
		t.Errorf("Tailscale disabled in settings: got %s", d.Kind)
	}
}

func TestMatchBypass(t *testing.T) {
	list := []string{" *.Example.com ", ".lan", "192.168.1.0/24", "fe80::/10", "host.only"}
	yes := []string{"example.com", "a.b.example.com", "x.lan", "192.168.1.9", "fe80::1", "HOST.ONLY", "127.0.0.1", "::1", "[::1]"}
	no := []string{"notexample.com", "lan.io", "192.168.2.1", "other.only", "example.org"}
	for _, h := range yes {
		if !MatchBypass(list, h) {
			t.Errorf("%s should bypass", h)
		}
	}
	for _, h := range no {
		if MatchBypass(list, h) {
			t.Errorf("%s should not bypass", h)
		}
	}
}

// echo server: replies with the first line it receives, prefixed.
func echoServer(t *testing.T, prefix string) string {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				line, _ := bufio.NewReader(c).ReadString('\n')
				io.WriteString(c, prefix+line)
			}(c)
		}
	}()
	return ln.Addr().String()
}

func roundTrip(t *testing.T, hubAddr, user, pass, target string) (string, error) {
	d, err := proxy.SOCKS5("tcp", hubAddr, &proxy.Auth{User: user, Password: pass}, proxy.Direct)
	if err != nil {
		return "", err
	}
	c, err := d.Dial("tcp", target)
	if err != nil {
		return "", err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	io.WriteString(c, "ping\n")
	b, err := io.ReadAll(c)
	return string(b), err
}

// httpConnectProxy: a tiny CONNECT proxy requiring Basic user:pw.
func httpConnectProxy(t *testing.T) (string, *int) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	n := new(int)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				req, err := http.ReadRequest(bufio.NewReader(c))
				if err != nil || req.Method != http.MethodConnect {
					return
				}
				if req.Header.Get("Proxy-Authorization") != "Basic dXNlcjpwdw==" {
					io.WriteString(c, "HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
					return
				}
				up, err := net.Dial("tcp", strings.Replace(req.Host, "echo.internal", "127.0.0.1", 1))
				if err != nil {
					io.WriteString(c, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
					return
				}
				*n++
				io.WriteString(c, "HTTP/1.1 200 Connection established\r\n\r\n")
				pipe(c, up)
			}(c)
		}
	}()
	return ln.Addr().String(), n
}

func TestSocksEndToEnd(t *testing.T) {
	direct := echoServer(t, "direct:")
	tailnetEcho := echoServer(t, "tailnet:")
	ts := newFake()
	ts.target = tailnetEcho

	// Upstream SOCKS5 = a second hub (it authenticates like any SOCKS5 proxy).
	// "echo.internal" is not loopback, so the main hub really sends it to
	// the upstream; the upstream (and the HTTP proxy) map it to the echo.
	const fakeHost = "echo.internal"
	_, echoPort, _ := net.SplitHostPort(direct)
	viaName := net.JoinHostPort(fakeHost, echoPort)
	up := New(nil, nil)
	up.dialDirect = func(ctx context.Context, n, a string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, n, strings.Replace(a, fakeHost, "127.0.0.1", 1))
	}
	up.Configure(Config{DefaultRoute: "direct"})
	upAddr, upPass, err := up.Start(0)
	if err != nil {
		t.Fatal(err)
	}
	defer up.Stop()
	upHost, upPortS, _ := net.SplitHostPort(upAddr)
	upPort, _ := strconv.Atoi(upPortS)

	httpAddr, httpCount := httpConnectProxy(t)
	hh, hpS, _ := net.SplitHostPort(httpAddr)
	hp, _ := strconv.Atoi(hpS)

	h := New(ts, t.Logf)
	h.Configure(Config{
		DefaultRoute: "direct",
		Tags:         map[string]string{"viaSocks": "proxy:s", "viaHTTP": "proxy:h", "viaHTTPBad": "proxy:hbad"},
		Upstreams: []Upstream{
			{ID: "s", Type: "socks5", Host: upHost, Port: upPort, Username: "default", Password: upPass},
			{ID: "h", Type: "http", Host: hh, Port: hp, Username: "user", Password: "pw"},
			{ID: "hbad", Type: "http", Host: hh, Port: hp, Username: "user", Password: "wrong"},
		},
		Tailscale: true,
	})
	addr, pass, err := h.Start(0)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Stop()

	if got, err := roundTrip(t, addr, "default", pass, direct); err != nil || got != "direct:ping\n" {
		t.Fatalf("direct: %q %v", got, err)
	}
	// Loopback never goes to an upstream, even on a proxy route.
	if got, err := roundTrip(t, addr, "viaSocks", pass, direct); err != nil || got != "direct:ping\n" {
		t.Fatalf("loopback bypass: %q %v", got, err)
	}
	if c, _ := up.Stats(); c != 0 {
		t.Fatalf("loopback must not reach the upstream, got %d", c)
	}
	// A tailnet IP goes through the (fake) tailnet whatever the tag says.
	if got, err := roundTrip(t, addr, "viaSocks", pass, "100.100.1.2:80"); err != nil || got != "tailnet:ping\n" {
		t.Fatalf("tailnet: %q %v", got, err)
	}
	if got, err := roundTrip(t, addr, "viaSocks", pass, viaName); err != nil || got != "direct:ping\n" {
		t.Fatalf("via upstream socks: %q %v", got, err)
	}
	if c, _ := up.Stats(); c != 1 {
		t.Fatalf("upstream socks should have carried 1 connection, got %d", c)
	}
	if got, err := roundTrip(t, addr, "viaHTTP", pass, viaName); err != nil || got != "direct:ping\n" || *httpCount != 1 {
		t.Fatalf("via http CONNECT: %q %v count=%d", got, err, *httpCount)
	}
	if _, err := roundTrip(t, addr, "viaHTTPBad", pass, viaName); err == nil {
		t.Fatal("proxy auth failure must fail the connection")
	}
	if _, err := roundTrip(t, addr, "default", "not-the-password", direct); err == nil {
		t.Fatal("wrong hub password must be refused")
	}
	// Restart keeps port and password.
	a2, p2, _ := h.Start(0)
	if a2 != addr || p2 != pass {
		t.Fatal("Start must be idempotent")
	}
	// Upstream test helper.
	if _, err := TestUpstream(Upstream{Type: "http", Host: hh, Port: hp, Username: "user", Password: "pw"}, viaName, 3*time.Second); err != nil {
		t.Fatalf("TestUpstream: %v", err)
	}
}
