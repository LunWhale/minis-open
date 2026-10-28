package nethub

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync"
	"testing"
)

type fakeSelfTailnet struct {
	*fakeTailnet
	self []netip.Addr
}

func (f fakeSelfTailnet) SelfAddrs() []netip.Addr { return f.self }

func covers(list []string, ip string) bool {
	a := netip.MustParseAddr(ip)
	for _, s := range list {
		if netip.MustParsePrefix(s).Contains(a) {
			return true
		}
	}
	return false
}

func has(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func locals(s ...string) []netip.Prefix {
	var out []netip.Prefix
	for _, x := range s {
		out = append(out, netip.MustParsePrefix(x))
	}
	return out
}

// hooked: what iSH does with the snapshot - exempt wins over hook.
func hooked(s HookSnapshot, ip string) bool {
	return covers(s.Hook, ip) && !covers(s.Exempt, ip)
}

func TestHookRoutesDirectShell(t *testing.T) {
	ts := newFake()
	ts.prefixes = append(ts.prefixes, netip.MustParsePrefix("10.1.1.0/24")) // home subnet route
	h := New(fakeSelfTailnet{ts, []netip.Addr{netip.MustParseAddr("100.90.1.2"), netip.MustParseAddr("fd7a:115c:a1e0::12")}}, nil)
	h.Configure(Config{DefaultRoute: "direct", Tags: map[string]string{"shell": "direct"}, Tailscale: true})

	// Away from home, on a 10.x network: the home subnet goes to the entry.
	s := h.HookRoutes("shell", locals("10.17.41.0/24"))
	if !s.Tailnet || s.Everything || s.Route != "direct" {
		t.Fatalf("flags: %+v", s)
	}
	for _, ip := range []string{"10.1.1.2", "100.101.102.103", "192.168.50.7", "fd7a:115c:a1e0::5"} {
		if !hooked(s, ip) {
			t.Errorf("%s not hooked: %+v", ip, s)
		}
	}
	for _, ip := range []string{"10.17.41.1", "1.1.1.1", "8.8.8.8", "2001:db8::1"} {
		if hooked(s, ip) {
			t.Errorf("%s hooked on a direct route: %+v", ip, s)
		}
	}
	if has(s.Hook, "0.0.0.0/0") {
		t.Errorf("exit-node 0/0 of Prefixes leaked into hook: %v", s.Hook)
	}
	if !has(s.Exempt, "10.17.41.0/24") || len(s.Self) != 2 {
		t.Errorf("exempt/self: %+v", s)
	}

	// At home: the Wi-Fi is the subnet route's LAN, so it stays direct.
	s = h.HookRoutes("shell", locals("10.1.1.33/24"))
	if hooked(s, "10.1.1.2") {
		t.Errorf("home LAN hooked while on it: %+v", s)
	}
	if !hooked(s, "100.101.102.103") {
		t.Errorf("tailnet lost at home: %+v", s)
	}

	// A broad LAN (10.0.0.0/8) with the home subnet inside it: the more
	// specific subnet route wins, the rest of the LAN stays direct.
	s = h.HookRoutes("shell", locals("10.0.0.0/8"))
	if !hooked(s, "10.1.1.2") || hooked(s, "10.2.3.4") || hooked(s, "10.1.2.1") || hooked(s, "10.255.0.1") {
		t.Errorf("broad LAN split wrong: exempt=%v", s.Exempt)
	}
	if len(s.Exempt) != 16 {
		t.Errorf("10/8 minus one /24 should be 16 prefixes, got %d: %v", len(s.Exempt), s.Exempt)
	}
}

func TestHookRoutesNodeDown(t *testing.T) {
	ts := newFake()
	ts.running = false
	h := New(ts, nil)
	h.Configure(Config{DefaultRoute: "direct", Tailscale: true})
	s := h.HookRoutes("shell", locals("10.17.41.0/24"))
	if s.Tailnet || len(s.Hook) != 0 || len(s.Exempt) != 0 {
		t.Fatalf("node down must hook nothing (Decide sends everything direct): %+v", s)
	}
	h.Configure(Config{DefaultRoute: "direct", Tailscale: false})
	ts.running = true
	if s := h.HookRoutes("shell", nil); len(s.Hook) != 0 {
		t.Fatalf("Tailscale off in settings must hook nothing: %+v", s)
	}
}

func TestHookRoutesExitNode(t *testing.T) {
	ts := newFake()
	ts.exitNode = true
	h := New(ts, nil)
	h.Configure(Config{DefaultRoute: "direct", Tags: map[string]string{"shell": "tailscale", "mcp": "direct"}, Tailscale: true})
	s := h.HookRoutes("shell", locals("192.168.1.0/24"))
	if !s.Everything || !hooked(s, "1.1.1.1") || !hooked(s, "2001:db8::1") || hooked(s, "192.168.1.20") {
		t.Fatalf("exit node: %+v", s)
	}
	// Same node, a direct tag: only the tailnet.
	if s := h.HookRoutes("mcp", nil); s.Everything || hooked(s, "1.1.1.1") {
		t.Fatalf("direct tag under an exit node: %+v", s)
	}
	ts.exitNode = false
	if s := h.HookRoutes("shell", nil); s.Everything {
		t.Fatalf("no exit node, tailscale route hooks 0/0: %+v", s)
	}
}

func TestHookRoutesProxy(t *testing.T) {
	ts := newFake()
	ts.prefixes = append(ts.prefixes, netip.MustParsePrefix("10.1.1.0/24"))
	h := New(ts, nil)
	h.Configure(Config{
		DefaultRoute: "direct",
		Tags:         map[string]string{"shell": "proxy:p1", "mcp": "proxy:gone"},
		Upstreams: []Upstream{{ID: "p1", Type: "http", Host: "127.0.0.1", Port: 1,
			Bypass: []string{"10.0.0.0/8", "*.corp.example", "203.0.113.9", "100.100.1.0/24", " 2001:db8::/32 "}}},
		Tailscale: true,
	})
	s := h.HookRoutes("shell", nil)
	if !s.Everything || !hooked(s, "1.1.1.1") {
		t.Fatalf("proxy route must hook 0/0: %+v", s)
	}
	// Bypass addresses go direct...
	for _, ip := range []string{"10.2.3.4", "203.0.113.9", "2001:db8::1"} {
		if hooked(s, ip) {
			t.Errorf("bypass %s hooked: exempt=%v", ip, s.Exempt)
		}
	}
	// ...but the tailnet comes first, as in Decide: the subnet route inside
	// the bypass CIDR and a bypass entry inside the tailnet stay hooked.
	for _, ip := range []string{"10.1.1.2", "100.100.1.5"} {
		if !hooked(s, ip) {
			t.Errorf("tailnet %s exempted by the bypass list: exempt=%v", ip, s.Exempt)
		}
		if d := h.Decide("shell", ip); d.Kind != "tailscale" {
			t.Errorf("Decide disagrees for %s: %+v", ip, d)
		}
	}
	for _, e := range s.Exempt {
		if strings.Contains(e, "corp") {
			t.Errorf("host-name bypass in exempt: %v", s.Exempt)
		}
	}
	// A deleted proxy degrades to direct, so only the tailnet is hooked.
	if s := h.HookRoutes("mcp", nil); s.Everything || hooked(s, "1.1.1.1") {
		t.Fatalf("missing proxy: %+v", s)
	}
}

// Every address the snapshot hooks is one Decide sends somewhere other than
// direct, and the other way round (bypass by host name aside).
func TestHookRoutesAgreesWithDecide(t *testing.T) {
	ts := newFake()
	ts.prefixes = append(ts.prefixes, netip.MustParsePrefix("10.1.1.0/24"))
	h := New(ts, nil)
	up := []Upstream{{ID: "p1", Type: "socks5", Host: "127.0.0.1", Port: 1, Bypass: []string{"10.0.0.0/8", "198.51.100.7"}}}
	ips := []string{"10.1.1.2", "10.9.9.9", "100.64.0.1", "100.101.102.103", "192.168.50.7", "198.51.100.7", "1.1.1.1", "fd7a:115c:a1e0::5", "2001:db8::1"}
	for _, route := range []string{"direct", "tailscale", "proxy:p1", "proxy:gone"} {
		for _, exit := range []bool{false, true} {
			ts.exitNode = exit
			h.Configure(Config{DefaultRoute: route, Upstreams: up, Tailscale: true})
			s := h.HookRoutes("shell", nil)
			for _, ip := range ips {
				want := h.Decide("shell", ip).Kind != "direct"
				if got := hooked(s, ip); got != want {
					t.Errorf("route=%s exit=%v %s: hooked=%v, Decide non-direct=%v", route, exit, ip, got, want)
				}
			}
		}
	}
}

func TestSubtractPrefixes(t *testing.T) {
	a := netip.MustParsePrefix("192.168.0.0/16")
	got := subtractPrefixes(a, locals("192.168.50.0/24", "192.168.50.128/25", "192.168.7.7/32"))
	n := 0
	for _, p := range got {
		n += 1 << (32 - p.Bits())
	}
	if n != 65536-256-1 {
		t.Fatalf("covered %d addresses, want %d: %v", n, 65536-256-1, got)
	}
	for _, p := range got {
		if p.Contains(netip.MustParseAddr("192.168.50.200")) || p.Contains(netip.MustParseAddr("192.168.7.7")) {
			t.Fatalf("hole not removed: %v", got)
		}
	}
	if got := subtractPrefixes(a, locals("192.0.0.0/8")); got != nil {
		t.Fatalf("covering hole: %v", got)
	}
	v6 := subtractPrefixes(netip.MustParsePrefix("2001:db8::/32"), locals("2001:db8:0:1::/64"))
	if len(v6) != 32 {
		t.Fatalf("v6 split: %d %v", len(v6), v6)
	}
}

// iSH authenticates as "shell~x1f": routed as "shell", logged with the id.
func TestEntryTagWithConnID(t *testing.T) {
	direct := echoServer(t, "direct:")
	var mu sync.Mutex
	var lines []string
	h := New(newFake(), func(f string, a ...any) {
		mu.Lock()
		lines = append(lines, fmt.Sprintf(f, a...))
		mu.Unlock()
	})
	// Default route: a dead upstream. Only the "shell" tag connects.
	h.Configure(Config{DefaultRoute: "proxy:p1", Tags: map[string]string{"shell": "direct"},
		Upstreams: []Upstream{{ID: "p1", Type: "socks5", Host: "127.0.0.1", Port: 1}}, Tailscale: true})
	h.dialDirect = func(ctx context.Context, n, a string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, n, direct)
	}
	addr, pass, err := h.Start(0)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Stop()
	got, err := roundTrip(t, addr, "shell~x1f", pass, "example.test:80")
	if err != nil || got != "direct:ping\n" {
		t.Fatalf("shell~x1f was not routed as shell: %q %v", got, err)
	}
	mu.Lock()
	joined := strings.Join(lines, "\n")
	mu.Unlock()
	if !strings.Contains(joined, "~x1f tag=shell ") {
		t.Fatalf("policy line lacks the client id or the plain tag:\n%s", joined)
	}
	if tag, id := SplitTag("prov:abc"); tag != "prov:abc" || id != "" {
		t.Fatalf("SplitTag(prov:abc) = %q %q", tag, id)
	}
}
