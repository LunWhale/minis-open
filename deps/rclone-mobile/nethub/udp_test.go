package nethub

import (
	"context"
	"encoding/binary"
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

	"golang.org/x/net/dns/dnsmessage"
)

// udpEcho is a UDP server on 127.0.0.1 that echoes with a prefix.
func udpEcho(t *testing.T, prefix string) *net.UDPConn {
	t.Helper()
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	go func() {
		buf := make([]byte, 65535)
		for {
			n, from, err := c.ReadFromUDP(buf)
			if err != nil {
				return
			}
			c.WriteToUDP(append([]byte(prefix), buf[:n]...), from)
		}
	}()
	return c
}

// udpTailnet is a fake node for UDP and DNS: its "tailnet" dials go to
// target, and it answers DNS queries itself.
type udpTailnet struct {
	mu       sync.Mutex
	running  bool
	exitNode bool
	prefixes []netip.Prefix
	suffix   string
	target   string
	dials    []string
	queries  []string
}

func (f *udpTailnet) Running() bool            { return f.running }
func (f *udpTailnet) Prefixes() []netip.Prefix { return f.prefixes }
func (f *udpTailnet) IsTailnetName(h string) bool {
	return f.suffix != "" && strings.HasSuffix(h, "."+f.suffix)
}
func (f *udpTailnet) ExitNodeActive() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.exitNode
}
func (f *udpTailnet) Dial(ctx context.Context, n, a string) (net.Conn, error) {
	f.mu.Lock()
	f.dials = append(f.dials, n+" "+a)
	f.mu.Unlock()
	var d net.Dialer
	return d.DialContext(ctx, n, f.target)
}
func (f *udpTailnet) QueryDNS(ctx context.Context, q []byte, tcp bool) ([]byte, error) {
	name, _ := dnsQuestion(q)
	f.mu.Lock()
	f.queries = append(f.queries, name)
	f.mu.Unlock()
	return dnsAnswerFor(q, "100.64.0.9"), nil
}
func (f *udpTailnet) dialed() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.dials...)
}
func (f *udpTailnet) asked() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.queries...)
}

func dnsQuery(id uint16, name string) []byte {
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: id, RecursionDesired: true})
	b.StartQuestions()
	b.Question(dnsmessage.Question{Name: dnsmessage.MustNewName(name + "."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET})
	out, _ := b.Finish()
	return out
}

func dnsAnswerFor(q []byte, ip string) []byte {
	var p dnsmessage.Parser
	h, _ := p.Start(q)
	qq, _ := p.Question()
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: h.ID, Response: true, RecursionAvailable: true})
	b.StartQuestions()
	b.Question(qq)
	b.StartAnswers()
	a := netip.MustParseAddr(ip).As4()
	b.AResource(dnsmessage.ResourceHeader{Name: qq.Name, Class: dnsmessage.ClassINET, TTL: 60}, dnsmessage.AResource{A: a})
	out, _ := b.Finish()
	return out
}

func dnsAnswerIP(t *testing.T, msg []byte) (uint16, string) {
	t.Helper()
	var p dnsmessage.Parser
	h, err := p.Start(msg)
	if err != nil {
		t.Fatalf("answer does not parse: %v", err)
	}
	p.SkipAllQuestions()
	answers, err := p.AllAnswers()
	if err != nil || len(answers) == 0 {
		t.Fatalf("no answer: %v", err)
	}
	r, ok := answers[0].Body.(*dnsmessage.AResource)
	if !ok {
		t.Fatalf("not an A record: %v", answers[0].Body)
	}
	return h.ID, netip.AddrFrom4(r.A).String()
}

// fakeResolver is a DNS server (UDP and TCP on one port) answering 93.184.216.34.
func fakeResolver(t *testing.T) string {
	t.Helper()
	u, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	port := u.LocalAddr().(*net.UDPAddr).Port
	l, err := net.Listen("tcp4", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		u.Close()
		t.Skip("cannot share the port for TCP:", err)
	}
	t.Cleanup(func() { u.Close(); l.Close() })
	go func() {
		buf := make([]byte, 1500)
		for {
			n, from, err := u.ReadFromUDP(buf)
			if err != nil {
				return
			}
			u.WriteToUDP(dnsAnswerFor(buf[:n], "93.184.216.34"), from)
		}
	}()
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				for {
					q, err := readDNSFrame(c)
					if err != nil {
						return
					}
					a := dnsAnswerFor(q, "93.184.216.34")
					f := make([]byte, 2+len(a))
					binary.BigEndian.PutUint16(f, uint16(len(a)))
					copy(f[2:], a)
					c.Write(f)
				}
			}()
		}
	}()
	return u.LocalAddr().String()
}

type logSink struct {
	mu    sync.Mutex
	lines []string
}

func (l *logSink) logf(format string, a ...any) {
	l.mu.Lock()
	l.lines = append(l.lines, fmt.Sprintf(format, a...))
	l.mu.Unlock()
}

func (l *logSink) has(sub string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, s := range l.lines {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}

// socksHello connects to the entry and authenticates as user.
func socksHello(t *testing.T, entry, pass, user string) net.Conn {
	t.Helper()
	c, err := net.DialTimeout("tcp", entry, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	c.SetDeadline(time.Now().Add(5 * time.Second))
	c.Write([]byte{5, 1, 2})
	var r [2]byte
	io.ReadFull(c, r[:])
	auth := []byte{1, byte(len(user))}
	auth = append(auth, user...)
	auth = append(auth, byte(len(pass)))
	auth = append(auth, pass...)
	c.Write(auth)
	if _, err := io.ReadFull(c, r[:]); err != nil || r[1] != 0 {
		t.Fatalf("auth failed: %v %v", err, r)
	}
	return c
}

type assocClient struct {
	ctl   net.Conn
	udp   *net.UDPConn
	relay *net.UDPAddr
}

// associate opens a client UDP socket and an association for it.
func associate(t *testing.T, entry, pass, user string) *assocClient {
	t.Helper()
	u, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { u.Close() })
	c := socksHello(t, entry, pass, user)
	t.Cleanup(func() { c.Close() })
	p := u.LocalAddr().(*net.UDPAddr).Port
	c.Write([]byte{5, cmdUDPAssociate, 0, 1, 127, 0, 0, 1, byte(p >> 8), byte(p)})
	var r [10]byte
	if _, err := io.ReadFull(c, r[:]); err != nil {
		t.Fatalf("associate reply: %v", err)
	}
	if r[1] != 0 {
		t.Fatalf("associate refused: %#x", r[1])
	}
	c.SetDeadline(time.Time{})
	return &assocClient{ctl: c, udp: u, relay: &net.UDPAddr{IP: net.IP(r[4:8]), Port: int(r[8])<<8 | int(r[9])}}
}

func (a *assocClient) send(t *testing.T, host string, port int, payload string) {
	t.Helper()
	if _, err := a.udp.WriteToUDP(append(udpHeader(host, port), payload...), a.relay); err != nil {
		t.Fatal(err)
	}
}

// recv returns the next datagram's source and payload.
func (a *assocClient) recv(t *testing.T) (string, string) {
	t.Helper()
	buf := make([]byte, 65535)
	a.udp.SetReadDeadline(time.Now().Add(3 * time.Second))
	n, from, err := a.udp.ReadFromUDP(buf)
	if err != nil {
		t.Fatalf("no datagram: %v", err)
	}
	if from.Port != a.relay.Port {
		t.Fatalf("datagram from %v, not the relay", from)
	}
	host, port, payload, err := parseUDPHeader(buf[:n])
	if err != nil {
		t.Fatal(err)
	}
	return net.JoinHostPort(host, strconv.Itoa(port)), string(payload)
}

// ended reports whether the entry closed the control connection.
func (a *assocClient) ended(wait time.Duration) bool {
	a.ctl.SetReadDeadline(time.Now().Add(wait))
	var b [1]byte
	_, err := a.ctl.Read(b[:])
	var ne net.Error
	return err != nil && !(errors.As(err, &ne) && ne.Timeout())
}

func newUDPHub(t *testing.T, ts Tailnet, cfg Config) (*Hub, string, string, *logSink) {
	t.Helper()
	logs := &logSink{}
	h := New(ts, logs.logf)
	h.Configure(cfg)
	addr, pass, err := h.Start(0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(h.Stop)
	return h, addr, pass, logs
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for i := 0; i < 100; i++ {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestUDPAssociateTailnetAndDirect(t *testing.T) {
	tailEcho, directEcho := udpEcho(t, "ts:"), udpEcho(t, "direct:")
	ts := &udpTailnet{running: true, prefixes: []netip.Prefix{netip.MustParsePrefix("100.64.0.0/10")},
		target: tailEcho.LocalAddr().String()}
	h, entry, pass, _ := newUDPHub(t, ts, Config{Tags: map[string]string{"shell": "direct"}, Tailscale: true})
	h.dialDirect = func(ctx context.Context, n, a string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, n, directEcho.LocalAddr().String())
	}
	a := associate(t, entry, pass, "shell~x1f")
	a.send(t, "100.100.1.2", 41641, "hi")
	if src, got := a.recv(t); src != "100.100.1.2:41641" || got != "ts:hi" {
		t.Fatalf("tailnet destination: got %q from %s", got, src)
	}
	a.send(t, "203.0.113.5", 123, "ntp")
	if src, got := a.recv(t); src != "203.0.113.5:123" || got != "direct:ntp" {
		t.Fatalf("direct destination: got %q from %s", got, src)
	}
	a.send(t, "2001:db8::7", 7, "six")
	if src, got := a.recv(t); src != "[2001:db8::7]:7" || got != "direct:six" {
		t.Fatalf("IPv6 destination: got %q from %s", got, src)
	}
	if d := ts.dialed(); len(d) != 1 || d[0] != "udp 100.100.1.2:41641" {
		t.Fatalf("tailnet dials: %v", d)
	}
	st := h.UDPStats()
	if st.Active != 1 || st.Flows != 3 || st.Sent != 3 || st.Received != 3 {
		t.Fatalf("stats: %+v", st)
	}
	// The same destination reuses its flow.
	a.send(t, "100.100.1.2", 41641, "again")
	a.recv(t)
	if d := ts.dialed(); len(d) != 1 {
		t.Fatalf("a second datagram dialed again: %v", d)
	}
	a.ctl.Close()
	waitFor(t, "the association to end with its control connection", func() bool { return h.UDPStats().Active == 0 })
	if h.UDPStats().Flows != 0 {
		t.Fatalf("flows left open: %+v", h.UDPStats())
	}
}

func TestUDPSpoofedSourceDropped(t *testing.T) {
	echo := udpEcho(t, "")
	h, entry, pass, logs := newUDPHub(t, nil, Config{})
	h.dialDirect = func(ctx context.Context, n, a string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, n, echo.LocalAddr().String())
	}
	a := associate(t, entry, pass, "shell")
	other, _ := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	defer other.Close()
	other.WriteToUDP(append(udpHeader("203.0.113.9", 9), "x"...), a.relay)
	waitFor(t, "the spoofed datagram to be counted", func() bool { return h.UDPStats().Spoofed == 1 })
	if h.UDPStats().Sent != 0 || !logs.has("not the declared client") {
		t.Fatalf("spoofed datagram was relayed or not logged: %+v", h.UDPStats())
	}
	// Fragments are dropped too.
	frag := udpHeader("203.0.113.9", 9)
	frag[2] = 1
	a.udp.WriteToUDP(append(frag, "f"...), a.relay)
	waitFor(t, "the fragment to be dropped", func() bool { return h.UDPStats().Malformed == 1 })
	// The real client still works.
	a.send(t, "203.0.113.9", 9, "ok")
	if _, got := a.recv(t); got != "ok" {
		t.Fatalf("got %q", got)
	}
}

func TestUDPAssociateRefusesNonLoopbackClient(t *testing.T) {
	_, entry, pass, _ := newUDPHub(t, nil, Config{})
	c := socksHello(t, entry, pass, "shell")
	defer c.Close()
	c.Write([]byte{5, cmdUDPAssociate, 0, 1, 10, 1, 1, 9, 0, 53})
	var r [10]byte
	if _, err := io.ReadFull(c, r[:]); err != nil || r[1] != repNotAllowed {
		t.Fatalf("want 0x02 for a client off the loopback, got %v %#x", err, r[1])
	}
}

func TestUDPIdleAndLimits(t *testing.T) {
	echo := udpEcho(t, "")
	h, entry, pass, logs := newUDPHub(t, nil, Config{})
	h.dialDirect = func(ctx context.Context, n, a string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, n, echo.LocalAddr().String())
	}
	h.mu.Lock()
	h.udpLimit = udpLimits{idle: 400 * time.Millisecond, dnsIdle: 400 * time.Millisecond, assocs: 2, flows: 2, sweep: 50 * time.Millisecond}
	h.mu.Unlock()

	// Flow limit: a third destination closes the least recently used flow.
	a := associate(t, entry, pass, "shell")
	for i, dst := range []string{"203.0.113.1", "203.0.113.2", "203.0.113.3"} {
		a.send(t, dst, 7, strconv.Itoa(i))
		a.recv(t)
		time.Sleep(10 * time.Millisecond)
	}
	if st := h.UDPStats(); st.Flows != 2 || !logs.has("destinations is the limit") {
		t.Fatalf("flow limit not applied: %+v", st)
	}
	a.send(t, "203.0.113.1", 7, "back")
	if _, got := a.recv(t); got != "back" {
		t.Fatalf("a closed flow did not reopen: %q", got)
	}

	// Association limit: a third association ends the least recently used.
	b := associate(t, entry, pass, "shell")
	time.Sleep(10 * time.Millisecond)
	a.send(t, "203.0.113.1", 7, "keep a fresh")
	a.recv(t)
	c := associate(t, entry, pass, "shell")
	if !b.ended(time.Second) {
		t.Fatal("the least recently used association was not ended")
	}
	if a.ended(50*time.Millisecond) || h.UDPStats().Evicted != 1 {
		t.Fatalf("wrong association evicted: %+v", h.UDPStats())
	}

	// Idle: with no traffic the association ends, and says so.
	if !c.ended(2 * time.Second) {
		t.Fatal("an idle association was not ended")
	}
	waitFor(t, "every association to end", func() bool { return h.UDPStats().Active == 0 })
	if !logs.has("reason=idle") {
		t.Fatal("no idle line in the log")
	}
}

func TestUDPProxyRouteSplit(t *testing.T) {
	tailEcho, directEcho := udpEcho(t, "ts:"), udpEcho(t, "direct:")
	ts := &udpTailnet{running: true, prefixes: []netip.Prefix{netip.MustParsePrefix("100.64.0.0/10")},
		target: tailEcho.LocalAddr().String()}
	h, entry, pass, logs := newUDPHub(t, ts, Config{Tags: map[string]string{"shell": "proxy:p1"}, Tailscale: true,
		Upstreams: []Upstream{{ID: "p1", Type: "http", Host: "127.0.0.1", Port: 1}}})
	h.dialDirect = func(ctx context.Context, n, a string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, n, directEcho.LocalAddr().String())
	}
	a := associate(t, entry, pass, "shell~x2")
	a.send(t, "203.0.113.5", 443, "quic")
	if _, got := a.recv(t); got != "direct:quic" {
		t.Fatalf("Q2: a non-tailnet datagram under a proxy route must go directly, got %q", got)
	}
	if !logs.has("rule=udp-direct(proxy-route)") {
		t.Fatal("Q2: udp-direct(proxy-route) not logged")
	}
	a.send(t, "100.70.0.1", 53, "tail")
	if _, got := a.recv(t); got != "ts:tail" {
		t.Fatalf("a tailnet datagram under a proxy route must go through the tailnet, got %q", got)
	}
}

func TestUDPDialFailureClassified(t *testing.T) {
	h, entry, pass, logs := newUDPHub(t, nil, Config{})
	h.dialDirect = func(ctx context.Context, n, a string) (net.Conn, error) {
		return nil, &net.OpError{Op: "dial", Net: n, Err: errors.New("connect: network is unreachable")}
	}
	a := associate(t, entry, pass, "shell~x3")
	a.send(t, "203.0.113.5", 7, "x")
	waitFor(t, "the failure to be counted", func() bool { return h.UDPStats().DialFailures == 1 })
	if !logs.has("FAIL stage=direct target=203.0.113.5:7 class=unreachable") && !logs.has("class=unreachable") {
		t.Fatalf("failure not classified: %v", logs.lines)
	}
	if a.ended(100 * time.Millisecond) {
		t.Fatal("one failed destination must not end the association")
	}
}

func TestDNSInterception(t *testing.T) {
	resolver := fakeResolver(t)
	ts := &udpTailnet{running: true, prefixes: []netip.Prefix{netip.MustParsePrefix("100.64.0.0/10")},
		suffix: "tail1234.ts.net"}
	h, entry, pass, logs := newUDPHub(t, ts, Config{Tags: map[string]string{"shell": "tailscale"}, Tailscale: true})
	rhost, rport, _ := net.SplitHostPort(resolver)
	port, _ := strconv.Atoi(rport)
	a := associate(t, entry, pass, "shell~x4~dns")

	ask := func(id uint16, name string) (string, uint16, string) {
		a.send(t, rhost, port, string(dnsQuery(id, name)))
		src, payload := a.recv(t)
		gotID, ip := dnsAnswerIP(t, []byte(payload))
		return src, gotID, ip
	}
	// A tailnet name: the node answers, as if from the guest's resolver.
	if src, id, ip := ask(0x1111, "nas.tail1234.ts.net"); src != resolver || id != 0x1111 || ip != "100.64.0.9" {
		t.Fatalf("tailnet name: %s %#x %s", src, id, ip)
	}
	// Any other name: the guest's own resolver, directly.
	if _, id, ip := ask(0x2222, "example.com"); id != 0x2222 || ip != "93.184.216.34" {
		t.Fatalf("public name: %#x %s", id, ip)
	}
	// Exit node, ExitNodeDNS off (the default): still the guest's resolver.
	ts.mu.Lock()
	ts.exitNode = true
	ts.mu.Unlock()
	if _, _, ip := ask(0x3333, "example.org"); ip != "93.184.216.34" {
		t.Fatalf("exit node, ExitNodeDNS off: %s", ip)
	}
	// ExitNodeDNS on: the node's resolver (through the exit node).
	h.Configure(Config{Tags: map[string]string{"shell": "tailscale"}, Tailscale: true, ExitNodeDNS: true})
	if _, _, ip := ask(0x4444, "example.net"); ip != "100.64.0.9" {
		t.Fatalf("exit node, ExitNodeDNS on: %s", ip)
	}
	if q := ts.asked(); len(q) != 2 || q[0] != "nas.tail1234.ts.net" || q[1] != "example.net" {
		t.Fatalf("node resolver asked: %v", q)
	}
	// The resolver is never dialed through the exit node.
	if d := ts.dialed(); len(d) != 0 {
		t.Fatalf("the guest's resolver went through the tailnet: %v", d)
	}
	if st := h.UDPStats(); st.DNSQueries != 4 || st.DNSTailnet != 2 || st.DNSFailures != 0 {
		t.Fatalf("stats: %+v", st)
	}
	if !logs.has("via=tailnet rule=tailnet-name") || !logs.has("via=resolver rule=route") ||
		!logs.has("rule=exit-node-dns") {
		t.Fatalf("decisions not logged: %v", logs.lines)
	}

	// DNS over TCP: a "~dns" CONNECT to the resolver.
	c := socksHello(t, entry, pass, "shell~x5~dns")
	defer c.Close()
	ip4 := net.ParseIP(rhost).To4()
	c.Write([]byte{5, 1, 0, 1, ip4[0], ip4[1], ip4[2], ip4[3], byte(port >> 8), byte(port)})
	var r [10]byte
	if _, err := io.ReadFull(c, r[:]); err != nil || r[1] != 0 {
		t.Fatalf("DNS CONNECT: %v %#x", err, r[1])
	}
	h.Configure(Config{Tags: map[string]string{"shell": "tailscale"}, Tailscale: true})
	for i, name := range []string{"box.tail1234.ts.net", "example.com"} {
		q := dnsQuery(uint16(0x5000+i), name)
		f := make([]byte, 2+len(q))
		binary.BigEndian.PutUint16(f, uint16(len(q)))
		copy(f[2:], q)
		c.Write(f)
		ans, err := readDNSFrame(c)
		if err != nil {
			t.Fatal(err)
		}
		_, ip := dnsAnswerIP(t, ans)
		want := map[int]string{0: "100.64.0.9", 1: "93.184.216.34"}[i]
		if ip != want {
			t.Fatalf("TCP %s: %s, want %s", name, ip, want)
		}
	}
}

func TestDNSNodeDownGoesToResolver(t *testing.T) {
	resolver := fakeResolver(t)
	ts := &udpTailnet{running: false, suffix: "tail1234.ts.net"}
	_, entry, pass, _ := newUDPHub(t, ts, Config{Tailscale: true})
	rhost, rport, _ := net.SplitHostPort(resolver)
	port, _ := strconv.Atoi(rport)
	a := associate(t, entry, pass, "shell~dns")
	a.send(t, rhost, port, string(dnsQuery(7, "nas.tail1234.ts.net")))
	_, payload := a.recv(t)
	if _, ip := dnsAnswerIP(t, []byte(payload)); ip != "93.184.216.34" || len(ts.asked()) != 0 {
		t.Fatalf("node down: the guest's resolver must answer, got %s", ip)
	}
}

func TestDNSServFailOverTCP(t *testing.T) {
	h, entry, pass, _ := newUDPHub(t, nil, Config{})
	h.dialDirect = func(ctx context.Context, n, a string) (net.Conn, error) {
		return nil, errors.New("connect: connection refused")
	}
	c := socksHello(t, entry, pass, "shell~x6~dns")
	defer c.Close()
	c.Write([]byte{5, 1, 0, 1, 198, 18, 0, 4, 0, 53})
	var r [10]byte
	io.ReadFull(c, r[:])
	q := dnsQuery(0x77, "example.com")
	f := make([]byte, 2+len(q))
	binary.BigEndian.PutUint16(f, uint16(len(q)))
	copy(f[2:], q)
	c.Write(f)
	ans, err := readDNSFrame(c)
	if err != nil {
		t.Fatal(err)
	}
	var p dnsmessage.Parser
	hdr, _ := p.Start(ans)
	if hdr.ID != 0x77 || hdr.RCode != dnsmessage.RCodeServerFailure {
		t.Fatalf("want SERVFAIL for id 0x77, got %+v", hdr)
	}
	if h.UDPStats().DNSFailures != 1 {
		t.Fatalf("failure not counted: %+v", h.UDPStats())
	}
}

func TestHookRoutesUDPAndDNS(t *testing.T) {
	ts := newFake()
	h := New(ts, nil)
	resolvers := []netip.Addr{netip.MustParseAddr("198.18.0.4"), netip.MustParseAddr("198.18.0.4"), netip.MustParseAddr("::ffff:10.0.0.1")}
	h.Configure(Config{Tags: map[string]string{"shell": "tailscale"}, Tailscale: true})
	ts.exitNode = true
	s := h.HookRoutesWithResolvers("shell", nil, resolvers)
	if !has(s.UDPHook, "0.0.0.0/0") || !s.DNSIntercept {
		t.Fatalf("exit node: UDP must take 0/0 and DNS be intercepted: %+v", s)
	}
	if len(s.Resolvers) != 2 || s.Resolvers[0] != "198.18.0.4" || s.Resolvers[1] != "10.0.0.1" {
		t.Fatalf("resolvers: %v", s.Resolvers)
	}
	h.Configure(Config{Tags: map[string]string{"shell": "proxy:p1"}, Tailscale: true,
		Upstreams: []Upstream{{ID: "p1", Type: "http", Host: "127.0.0.1", Port: 1}}})
	s = h.HookRoutesWithResolvers("shell", nil, resolvers)
	if !has(s.Hook, "0.0.0.0/0") || has(s.UDPHook, "0.0.0.0/0") || !has(s.UDPHook, "100.64.0.0/10") {
		t.Fatalf("proxy route: TCP takes 0/0, UDP only the tailnet: %+v", s)
	}
	ts.running = false
	s = h.HookRoutesWithResolvers("shell", nil, resolvers)
	if s.DNSIntercept || len(s.UDPHook) != 0 {
		t.Fatalf("node down: no DNS interception, no tailnet UDP: %+v", s)
	}
	if old := h.HookRoutes("shell", nil); len(old.Resolvers) != 0 || old.DNSIntercept {
		t.Fatalf("HookRoutes (stage 1) must not intercept DNS: %+v", old)
	}
}

func TestEntryUserDNSMark(t *testing.T) {
	for _, c := range []struct{ user, tag, id string }{
		{"shell~x1f~dns", "shell", "x1f"}, {"shell~dns", "shell", ""}, {"shell~x2", "shell", "x2"},
	} {
		tag, rest := SplitTag(c.user)
		id, _ := strings.CutSuffix(rest, "~dns")
		if id == "dns" {
			id = ""
		}
		if tag != c.tag || id != c.id {
			t.Errorf("%s: tag=%q id=%q", c.user, tag, id)
		}
	}
}

func TestShellProbes(t *testing.T) {
	resolver := fakeResolver(t)
	ts := &udpTailnet{running: true, prefixes: []netip.Prefix{netip.MustParsePrefix("100.64.0.0/10")},
		suffix: "tail1234.ts.net"}
	// Even with an exit node, the loopback echo of the UDP self-test is
	// reached directly.
	ts.exitNode = true
	h, _, _, _ := newUDPHub(t, ts, Config{DefaultRoute: "tailscale", Tailscale: true})
	if _, err := h.UDPSelfTest(3 * time.Second); err != nil {
		t.Fatalf("UDP self-test: %v", err)
	}
	if d := ts.dialed(); len(d) != 0 {
		t.Fatalf("the loopback echo went through the tailnet: %v", d)
	}
	res := h.DNSProbe(resolver, []string{"nas.tail1234.ts.net", "example.com"})
	if len(res) != 2 || res[0].Via != "tailnet" || res[0].Answers != 1 || res[0].Rcode != "Success" ||
		res[1].Via != "resolver" || res[1].Rule != "route" || res[1].Answers != 1 {
		t.Fatalf("DNS probe: %+v", res)
	}
	h.Stop()
	if _, err := h.UDPSelfTest(time.Second); err == nil || Stage(err) != "entry" {
		t.Fatalf("a stopped entry must fail at stage entry: %v", err)
	}
}
