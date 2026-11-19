package nethub

import (
	"context"
	"errors"
	"net"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// familyTailnet answers a dial by network family: "tcp4" / "tcp6" fail with
// the given errors (nil = connect to target), anything else dials target.
type familyTailnet struct {
	fakeTailnet
	fail4, fail6 error
	networks     []string
}

func (f *familyTailnet) Dial(ctx context.Context, n, a string) (net.Conn, error) {
	f.networks = append(f.networks, n+" "+a)
	switch {
	case n == "tcp4" && f.fail4 != nil:
		return nil, f.fail4
	case n == "tcp6" && f.fail6 != nil:
		return nil, f.fail6
	}
	var d net.Dialer
	return d.DialContext(ctx, "tcp", f.target)
}

func newFamily(t *testing.T) *familyTailnet {
	t.Helper()
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
			c.Close()
		}
	}()
	return &familyTailnet{fakeTailnet: fakeTailnet{running: true, exitNode: true, suffix: "tail1234.ts.net", target: ln.Addr().String()}}
}

func exitHub(ts Tailnet) *Hub {
	h := New(ts, nil)
	h.Configure(Config{DefaultRoute: "tailscale", Tailscale: true})
	return h
}

// FIX-261025-27: a host name through the exit node is dialed as IPv4 first.
func TestTailnetHostNameDialsIPv4First(t *testing.T) {
	ts := newFamily(t)
	h := exitHub(ts)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, d, err := h.DialVia(ctx, "default", "example.com:443")
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	c.Close()
	if d.Kind != "tailscale" || d.Rule != "exit-node" {
		t.Fatalf("decision = %+v", d)
	}
	if len(ts.networks) != 1 || ts.networks[0] != "tcp4 example.com:443" {
		t.Fatalf("dials = %v, want one tcp4 dial", ts.networks)
	}
}

// An IPv6-only name: the IPv4 attempt fails (no A record) and IPv6 is tried.
func TestTailnetHostNameFallsBackToIPv6(t *testing.T) {
	ts := newFamily(t)
	ts.fail4 = errors.New("lookup v6only.example: no such host")
	h := exitHub(ts)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, err := h.DialVia(ctx, "default", "v6only.example:443")
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	c.Close()
	if strings.Join(ts.networks, ",") != "tcp4 v6only.example:443,tcp6 v6only.example:443" {
		t.Fatalf("dials = %v", ts.networks)
	}
}

// Both families failing reports both reasons, classified by the IPv4 one.
func TestTailnetHostNameBothFamiliesFail(t *testing.T) {
	ts := newFamily(t)
	ts.fail4 = errors.New("connect tcp 1.2.3.4:443: connection refused")
	ts.fail6 = errors.New("connect tcp [2001:db8::1]:443: network is unreachable")
	h := exitHub(ts)
	_, _, err := h.DialVia(context.Background(), "default", "example.com:443")
	if err == nil {
		t.Fatal("want an error")
	}
	if !strings.Contains(err.Error(), "refused") || !strings.Contains(err.Error(), "IPv6: ") {
		t.Fatalf("err = %v", err)
	}
	if got := Classify(err); got != ClassRefused {
		t.Fatalf("class = %s, want %s", got, ClassRefused)
	}
}

// IP literals and tailnet names are dialed once, as given.
func TestTailnetLiteralAndTailnetNameDialAsGiven(t *testing.T) {
	ts := newFamily(t)
	h := exitHub(ts)
	for _, addr := range []string{"93.184.215.14:443", "[2606:2800:21f:cb07:6820:80da:af6b:8b2c]:443", "nas.tail1234.ts.net:22"} {
		ts.networks = nil
		c, _, err := h.DialVia(context.Background(), "default", addr)
		if err != nil {
			t.Fatalf("%s: %v", addr, err)
		}
		c.Close()
		if len(ts.networks) != 1 || ts.networks[0] != "tcp "+addr {
			t.Fatalf("%s: dials = %v", addr, ts.networks)
		}
	}
}

// FIX-261025-27: loopback never goes to the exit node, whatever the scope.
func TestTailscaleRouteKeepsLoopbackLocal(t *testing.T) {
	h := exitHub(newFamily(t))
	for _, host := range []string{"127.0.0.1", "127.8.9.10", "::1", "[::1]", "localhost", "api.localhost"} {
		d := h.Decide("diag", host)
		if d.Kind != "direct" || d.Rule != "loopback" {
			t.Errorf("%s: %+v, want direct/loopback", host, d)
		}
	}
	if d := h.Decide("default", "example.com"); d.Kind != "tailscale" {
		t.Errorf("example.com: %+v, want tailscale", d)
	}
}

// v6Reporter adds ExitNodeIPv6 to the family fake.
type v6Reporter struct {
	*familyTailnet
	v6 bool
}

func (r v6Reporter) ExitNodeIPv6() bool { return r.v6 }

func aaaaQuery(t *testing.T, name string, qt dnsmessage.Type) []byte {
	t.Helper()
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: 0x4242, RecursionDesired: true})
	if err := b.StartQuestions(); err != nil {
		t.Fatal(err)
	}
	if err := b.Question(dnsmessage.Question{Name: dnsmessage.MustNewName(name + "."), Type: qt, Class: dnsmessage.ClassINET}); err != nil {
		t.Fatal(err)
	}
	q, err := b.Finish()
	if err != nil {
		t.Fatal(err)
	}
	return q
}

func noData(t *testing.T, answer []byte) bool {
	t.Helper()
	var p dnsmessage.Parser
	h, err := p.Start(answer)
	if err != nil {
		t.Fatal(err)
	}
	if err := p.SkipAllQuestions(); err != nil {
		t.Fatal(err)
	}
	as, err := p.AllAnswers()
	if err != nil {
		t.Fatal(err)
	}
	return h.ID == 0x4242 && h.Response && h.RCode == dnsmessage.RCodeSuccess && len(as) == 0
}

// FIX-261025-27: an exit node without ::/0 gets "no AAAA" for names that
// leave through it, so the shell's programs connect over IPv4. The guest's
// resolver (127.0.0.1:1) is never asked - asking it would fail the test.
func TestShellDNSHoldsBackAAAAWithoutExitIPv6(t *testing.T) {
	h := exitHub(v6Reporter{familyTailnet: newFamily(t), v6: false})
	ans, err := h.answerDNS("t", "shell", "127.0.0.1:1", aaaaQuery(t, "ip.fm", dnsmessage.TypeAAAA), false, nil)
	if err != nil || !noData(t, ans) {
		t.Fatalf("AAAA: err=%v, want an empty NOERROR answer", err)
	}
	// A records and tailnet names are answered as before (here: the dead
	// resolver fails them, proving they were not synthesized).
	if _, err := h.answerDNS("t", "shell", "127.0.0.1:1", aaaaQuery(t, "ip.fm", dnsmessage.TypeA), false, nil); err == nil {
		t.Fatal("A query was synthesized")
	}
}

func TestShellDNSKeepsAAAAWhenExitRoutesIPv6(t *testing.T) {
	h := exitHub(v6Reporter{familyTailnet: newFamily(t), v6: true})
	if _, err := h.answerDNS("t", "shell", "127.0.0.1:1", aaaaQuery(t, "ip.fm", dnsmessage.TypeAAAA), false, nil); err == nil {
		t.Fatal("AAAA was synthesized although the exit node routes IPv6")
	}
}

// An IPv6 dial that the exit node cannot reach turns the filter on; one
// that works turns it off again.
func TestExitIPv6UnreachableDialTurnsFilterOn(t *testing.T) {
	ts := newFamily(t)
	h := exitHub(ts)
	if !h.exitIPv6Usable() {
		t.Fatal("usable before any failure")
	}
	d := Decision{Kind: "tailscale", Rule: "exit-node"}
	h.noteExitIPv6(d, "[2606:4700::1]:80", errors.New("connect tcp [2606:4700::1]:80: network is unreachable"))
	if h.exitIPv6Usable() {
		t.Fatal("still usable after an unreachable IPv6 dial")
	}
	ans, err := h.answerDNS("t", "shell", "127.0.0.1:1", aaaaQuery(t, "example.com", dnsmessage.TypeAAAA), false, nil)
	if err != nil || !noData(t, ans) {
		t.Fatalf("AAAA after failure: err=%v", err)
	}
	h.noteExitIPv6(Decision{Kind: "tailscale", Rule: "tailnet"}, "[fd7a:115c:a1e0::1]:22", errors.New("network is unreachable"))
	h.noteExitIPv6(d, "[2606:4700::1]:80", nil)
	if !h.exitIPv6Usable() {
		t.Fatal("not usable after an IPv6 dial worked")
	}
}

// Direct shells and tailnet names are never filtered.
func TestShellDNSFilterLeavesDirectAndTailnetAlone(t *testing.T) {
	ts := v6Reporter{familyTailnet: newFamily(t), v6: false}
	h := New(ts, nil)
	h.Configure(Config{DefaultRoute: "direct", Tailscale: true})
	if _, err := h.answerDNS("t", "shell", "127.0.0.1:1", aaaaQuery(t, "ip.fm", dnsmessage.TypeAAAA), false, nil); err == nil {
		t.Fatal("direct route: AAAA synthesized")
	}
}

// The first AAAA through an exit node whose IPv6 is unreachable is already
// held back: one probe dial finds out before answering.
func TestShellDNSProbesExitIPv6BeforeFirstAnswer(t *testing.T) {
	ts := newFamily(t)
	ts.fail6 = errors.New("connect tcp [2606:4700:4700::1111]:443: network is unreachable")
	h := exitHub(ts)
	ans, err := h.answerDNS("t", "shell", "127.0.0.1:1", aaaaQuery(t, "ip.fm", dnsmessage.TypeAAAA), false, nil)
	if err != nil || !noData(t, ans) {
		t.Fatalf("first AAAA: err=%v, want an empty NOERROR answer", err)
	}
	if len(ts.networks) != 1 || !strings.HasPrefix(ts.networks[0], "tcp6 ") {
		t.Fatalf("dials = %v, want one tcp6 probe", ts.networks)
	}
	// Remembered: no second probe.
	h.answerDNS("t", "shell", "127.0.0.1:1", aaaaQuery(t, "example.com", dnsmessage.TypeAAAA), false, nil)
	if len(ts.networks) != 1 {
		t.Fatalf("probed again: %v", ts.networks)
	}
}

// onlineReporter adds ExitNodeOnline to the family fake.
type onlineReporter struct {
	*familyTailnet
	online bool
}

func (r onlineReporter) ExitNodeOnline() bool { return r.online }

// FIX-261025-27: with the exit node offline the node would dial a public
// address through the system network; the hub refuses instead, so the
// route's fail-closed choice (not a silent direct connection) decides.
func TestOfflineExitNodeRefusesInsteadOfLeaking(t *testing.T) {
	fam := newFamily(t)
	h := exitHub(onlineReporter{familyTailnet: fam, online: false})
	for _, addr := range []string{"104.21.62.176:80", "example.com:443"} {
		_, d, err := h.DialVia(context.Background(), "shell", addr)
		if err == nil {
			t.Fatalf("%s: dialed through an offline exit node", addr)
		}
		if d.Rule != "exit-node" || Classify(err) != ClassUnreachable {
			t.Fatalf("%s: rule=%s class=%s err=%v", addr, d.Rule, Classify(err), err)
		}
	}
	if len(fam.networks) != 0 {
		t.Fatalf("the node was asked to dial: %v", fam.networks)
	}
	// Tailnet destinations do not depend on the exit node.
	c, _, err := h.DialVia(context.Background(), "shell", "nas.tail1234.ts.net:22")
	if err != nil {
		t.Fatalf("tailnet name: %v", err)
	}
	c.Close()
	// Online again: dials go through.
	h2 := exitHub(onlineReporter{familyTailnet: fam, online: true})
	c, _, err = h2.DialVia(context.Background(), "shell", "104.21.62.176:80")
	if err != nil {
		t.Fatalf("online: %v", err)
	}
	c.Close()
}
