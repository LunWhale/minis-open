package nethub

import (
	"encoding/binary"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// [FEAT-261021-23] proot's connected UDP sockets and TCP DNS through the
// xmap listener: what proot writes, what the guest gets back.

// xudpGuest is a guest UDP socket connected to the map's UDP port, with the
// destination file proot writes once connect() returned.
func xudpGuest(t *testing.T, x *XMap, dir, file string) *net.UDPConn {
	t.Helper()
	c, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: x.UDPPort()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	lport := c.LocalAddr().(*net.UDPAddr).Port
	os.WriteFile(filepath.Join(dir, fmt.Sprintf("u%d", lport)), []byte(file), 0o600)
	return c
}

func xudpRoundTrip(t *testing.T, c *net.UDPConn, msg string) string {
	t.Helper()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.Write([]byte(msg)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 65535)
	n, err := c.Read(buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return string(buf[:n])
}

func TestXMapUDPRoutesConnectedSockets(t *testing.T) {
	tailEcho, directEcho := udpEcho(t, "ts:"), udpEcho(t, "direct:")
	ts := &udpTailnet{running: true, prefixes: []netip.Prefix{netip.MustParsePrefix("100.64.0.0/10")},
		target: tailEcho.LocalAddr().String()}
	h, _, _, logs := newUDPHub(t, ts, Config{Tags: map[string]string{"shell": "tailscale"}, Tailscale: true})
	dir := t.TempDir()
	x := NewXMap(h, dir, "shell")
	if _, _, err := x.Start(); err != nil {
		t.Fatal(err)
	}
	defer x.Stop()

	// A tailnet destination: through the node, many datagrams on one session.
	g := xudpGuest(t, x, dir, "dst 100.64.0.7 9999\nid x3\n")
	for i := 0; i < 3; i++ {
		if got := xudpRoundTrip(t, g, fmt.Sprint("hello", i)); got != fmt.Sprint("ts:hello", i) {
			t.Fatalf("tailnet: %q", got)
		}
	}
	if d := ts.dialed(); len(d) != 1 || d[0] != "udp 100.64.0.7:9999" {
		t.Fatalf("node dials: %v", d)
	}
	// Anything else: direct, to where the guest was going.
	dp := directEcho.LocalAddr().(*net.UDPAddr).Port
	g2 := xudpGuest(t, x, dir, fmt.Sprintf("dst 127.0.0.1 %d\n", dp))
	if got := xudpRoundTrip(t, g2, "hi"); got != "direct:hi" {
		t.Fatalf("direct: %q", got)
	}
	st := x.UDPStats()
	if st.Active != 2 || st.Opened != 2 || st.Sent != 4 || st.Received != 4 {
		t.Fatalf("stats: %+v", st)
	}
	if !logs.has("udp tag=shell host=100.64.0.7:9999") {
		t.Fatalf("policy not logged: %v", logs.lines)
	}
	// Stop closes the sessions and removes their files.
	x.Stop()
	if st := x.UDPStats(); st.Active != 0 {
		t.Fatalf("after stop: %+v", st)
	}
	if left, _ := os.ReadDir(dir); len(left) != 0 {
		t.Fatalf("files left: %v", left)
	}
}

func TestXMapUDPDropsUnmappedPorts(t *testing.T) {
	h, _, _, _ := newUDPHub(t, &udpTailnet{}, Config{})
	dir := t.TempDir()
	x := NewXMap(h, dir, "shell")
	x.Start()
	defer x.Stop()
	c, _ := net.DialUDP("udp4", nil, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: x.UDPPort()})
	defer c.Close()
	c.Write([]byte("nobody wrote my file"))
	waitFor(t, "unmapped count", func() bool { return x.UDPStats().Unmapped == 1 })
	c.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	if _, err := c.Read(make([]byte, 10)); err == nil {
		t.Fatal("an unmapped port got an answer")
	}
}

func TestXMapUDPSessionsGoIdle(t *testing.T) {
	echo := udpEcho(t, "e:")
	h, _, _, _ := newUDPHub(t, &udpTailnet{}, Config{})
	h.mu.Lock()
	h.udpLimit = udpLimits{idle: 50 * time.Millisecond, dnsIdle: 50 * time.Millisecond, assocs: 4, flows: 4, sweep: time.Hour}
	h.mu.Unlock()
	dir := t.TempDir()
	x := NewXMap(h, dir, "shell")
	x.Start()
	defer x.Stop()
	g := xudpGuest(t, x, dir, fmt.Sprintf("dst 127.0.0.1 %d\n", echo.LocalAddr().(*net.UDPAddr).Port))
	xudpRoundTrip(t, g, "x")
	time.Sleep(80 * time.Millisecond)
	x.sweepSessions()
	if st := x.UDPStats(); st.Active != 0 {
		t.Fatalf("idle session kept: %+v", st)
	}
	// The socket is still the guest's: its file stays, the next datagram
	// opens a new session, and the age sweep leaves it alone.
	x.sweep(time.Nanosecond)
	if got := xudpRoundTrip(t, g, "again"); got != "e:again" {
		t.Fatalf("after idle: %q", got)
	}
	if st := x.UDPStats(); st.Active != 1 || st.Opened != 2 {
		t.Fatalf("stats after idle: %+v", st)
	}
}

func TestXMapDNSOverUDPAndTCP(t *testing.T) {
	resolver := fakeResolver(t)
	ts := &udpTailnet{running: true, prefixes: []netip.Prefix{netip.MustParsePrefix("100.64.0.0/10")},
		suffix: "tail1234.ts.net"}
	h, _, _, logs := newUDPHub(t, ts, Config{Tags: map[string]string{"shell": "tailscale"}, Tailscale: true})
	dir := t.TempDir()
	x := NewXMap(h, dir, "shell")
	x.Start()
	defer x.Stop()
	rhost, rport, _ := net.SplitHostPort(resolver)

	// UDP: Go's or glibc's resolver, a socket connected to the nameserver.
	g := xudpGuest(t, x, dir, fmt.Sprintf("dst %s %s\nid x8\ndns\n", rhost, rport))
	for i, c := range []struct{ name, ip string }{{"nas.tail1234.ts.net", "100.64.0.9"}, {"example.com", "93.184.216.34"}} {
		ans := xudpRoundTrip(t, g, string(dnsQuery(uint16(0x100+i), c.name)))
		if id, ip := dnsAnswerIP(t, []byte(ans)); id != uint16(0x100+i) || ip != c.ip {
			t.Fatalf("udp %s: %#x %s", c.name, id, ip)
		}
	}
	if st := x.UDPStats(); st.DNS != 2 {
		t.Fatalf("stats: %+v", st)
	}

	// TCP: a connect() to the nameserver's port 53 marked "dns".
	p4, _ := x.Ports()
	c, err := net.Dial("tcp4", fmt.Sprintf("127.0.0.1:%d", p4))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	lport := c.LocalAddr().(*net.TCPAddr).Port
	os.WriteFile(filepath.Join(dir, fmt.Sprint(lport)), []byte(fmt.Sprintf("dst %s %s\nid x9\ndns\n", rhost, rport)), 0o600)
	c.SetDeadline(time.Now().Add(5 * time.Second))
	q := dnsQuery(0x777, "box.tail1234.ts.net")
	f := make([]byte, 2+len(q))
	binary.BigEndian.PutUint16(f, uint16(len(q)))
	copy(f[2:], q)
	c.Write(f)
	ans, err := readDNSFrame(c)
	if err != nil {
		t.Fatal(err)
	}
	if id, ip := dnsAnswerIP(t, ans); id != 0x777 || ip != "100.64.0.9" {
		t.Fatalf("tcp: %#x %s", id, ip)
	}
	if !logs.has("tcp dns resolver=") || !logs.has("udp dns resolver=") {
		t.Fatalf("not logged: %s", strings.Join(logs.lines, "\n"))
	}
}
