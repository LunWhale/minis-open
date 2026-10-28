package nethub

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// [FEAT-261021-11] The listener behind proot's xnet extension: proot writes
// the destination to <dir>/<local port>; the connection is routed for the
// shell's tag and relayed.

func xmapConnect(t *testing.T, x *XMap, dir, dst string) net.Conn {
	t.Helper()
	p4, _ := x.Ports()
	c, err := net.Dial("tcp4", fmt.Sprintf("127.0.0.1:%d", p4))
	if err != nil {
		t.Fatal(err)
	}
	lport := c.LocalAddr().(*net.TCPAddr).Port
	host, port, _ := net.SplitHostPort(dst)
	// What proot writes once connect() returned.
	os.WriteFile(filepath.Join(dir, fmt.Sprint(lport)), []byte(fmt.Sprintf("dst %s %s\nid x7\n", host, port)), 0o600)
	return c
}

func echoLine(t *testing.T, c net.Conn, line string) string {
	t.Helper()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	fmt.Fprintf(c, "%s\n", line)
	got, err := bufio.NewReader(c).ReadString('\n')
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return strings.TrimSpace(got)
}

func TestXMapRoutesTheShellsTailnetAndDirectConnections(t *testing.T) {
	ts := newFake()
	ts.target = echoServer(t, "tailnet:")
	direct := echoServer(t, "direct:")
	h := New(ts, t.Logf)
	h.Configure(Config{DefaultRoute: "direct", Tags: map[string]string{"shell": "direct"}, Tailscale: true})
	h.dialDirect = func(ctx context.Context, n, a string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, n, direct)
	}
	dir := t.TempDir()
	x := NewXMap(h, dir, "shell")
	if _, _, err := x.Start(); err != nil {
		t.Fatal(err)
	}
	defer x.Stop()

	// A tailnet address goes through the tailnet even on a direct route.
	c := xmapConnect(t, x, dir, "100.64.0.42:22")
	if got := echoLine(t, c, "hi"); got != "tailnet:hi" {
		t.Fatalf("tailnet: got %q", got)
	}
	c.Close()
	if len(ts.dials) != 1 || ts.dials[0] != "100.64.0.42:22" {
		t.Fatalf("tailnet dials %v", ts.dials)
	}
	// Anything else the policy calls direct goes direct.
	c = xmapConnect(t, x, dir, "93.184.216.34:443")
	if got := echoLine(t, c, "yo"); got != "direct:yo" {
		t.Fatalf("direct: got %q", got)
	}
	c.Close()
	// Each file is consumed.
	time.Sleep(50 * time.Millisecond)
	if left, _ := os.ReadDir(dir); len(left) != 0 {
		t.Fatalf("files left: %v", left)
	}
}

func TestXMapClosesAConnectionWithoutADestination(t *testing.T) {
	h := New(newFake(), t.Logf)
	dir := t.TempDir()
	x := NewXMap(h, dir, "shell")
	p4, _, err := x.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer x.Stop()
	c, err := net.Dial("tcp4", fmt.Sprintf("127.0.0.1:%d", p4))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetReadDeadline(time.Now().Add(xmapWait + 2*time.Second))
	t0 := time.Now()
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Fatal("expected the connection to be closed")
	}
	if el := time.Since(t0); el < xmapWait-200*time.Millisecond {
		t.Fatalf("closed after %v, before the wait ran out", el)
	}
	if _, f := x.Stats(); f != 1 {
		t.Fatalf("failures %d", f)
	}
}

func TestXMapStartIsIdempotentAndStopSweeps(t *testing.T) {
	h := New(newFake(), nil)
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "12345"), []byte("dst 1.2.3.4 80\n"), 0o600) // from an earlier process
	x := NewXMap(h, dir, "shell")
	a4, a6, err := x.Start()
	if err != nil || a4 == 0 {
		t.Fatalf("start: %v %d", err, a4)
	}
	if left, _ := os.ReadDir(dir); len(left) != 0 {
		t.Fatal("stale destination kept at start")
	}
	b4, b6, _ := x.Start()
	if a4 != b4 || a6 != b6 {
		t.Fatal("a second Start moved the ports")
	}
	x.Stop()
	if p4, _ := x.Ports(); p4 != 0 {
		t.Fatal("ports after stop")
	}
	if _, err := net.DialTimeout("tcp4", fmt.Sprintf("127.0.0.1:%d", a4), time.Second); err == nil {
		t.Fatal("still listening after stop")
	}
}

func TestParseXMapFile(t *testing.T) {
	for in, want := range map[string]string{
		"dst 100.64.0.42 22\nid x1f\n": "100.64.0.42:22",
		"dst fd7a:115c:a1e0::1 443\n":    "[fd7a:115c:a1e0::1]:443",
	} {
		got, err := parseXMapFile(in)
		if err != nil || got.addr != want || got.dns {
			t.Errorf("%q -> %+v, %v", in, got, err)
		}
	}
	for _, bad := range []string{"", "dst nothost 22\n", "dst 1.2.3.4 0\n", "dst 1.2.3.4 70000\n", "id x1\n"} {
		if _, err := parseXMapFile(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	if d, _ := parseXMapFile("dst 1.2.3.4 80\nid x9\n"); d.clientID != "x9" {
		t.Errorf("id %q", d.clientID)
	}
	// [FEAT-261021-23] the guest's resolver
	if d, _ := parseXMapFile("dst 198.18.0.4 53\nid x2\ndns\n"); !d.dns || d.addr != "198.18.0.4:53" {
		t.Errorf("dns file: %+v", d)
	}
}

func TestXMapTreatsAConnectThenCloseAsAProbe(t *testing.T) {
	h := New(newFake(), t.Logf)
	dir := t.TempDir()
	x := NewXMap(h, dir, "shell")
	p4, _, err := x.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer x.Stop()
	c, err := net.Dial("tcp4", fmt.Sprintf("127.0.0.1:%d", p4))
	if err != nil {
		t.Fatal(err)
	}
	c.Close() // what proot's probe does
	time.Sleep(300 * time.Millisecond)
	if conns, f := x.Stats(); f != 0 || conns != 0 {
		t.Fatalf("a probe counted: conns=%d failures=%d", conns, f)
	}
}
