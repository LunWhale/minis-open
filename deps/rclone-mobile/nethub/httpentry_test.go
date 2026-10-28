package nethub

import (
	"bufio"
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

func basic(user, pass string) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(user+":"+pass))
}

// connectVia opens a CONNECT tunnel through the HTTP front and sends one line.
func connectVia(t *testing.T, front, auth, target, line string) (int, string) {
	t.Helper()
	c, err := net.Dial("tcp", front)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n", target, target)
	if auth != "" {
		fmt.Fprintf(c, "Proxy-Authorization: %s\r\n", auth)
	}
	io.WriteString(c, "\r\n")
	br := bufio.NewReader(c)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodConnect})
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 200 {
		return resp.StatusCode, resp.Header.Get("Proxy-Authenticate")
	}
	io.WriteString(c, line+"\n")
	got, _ := br.ReadString('\n')
	return 200, strings.TrimSpace(got)
}

func TestHTTPFront(t *testing.T) {
	direct := echoServer(t, "direct:")
	tailnet := echoServer(t, "tailnet:")
	ts := newFake()
	ts.target = tailnet
	h := New(ts, nil)
	h.Configure(Config{DefaultRoute: "direct", Tailscale: true})
	h.dialDirect = func(ctx context.Context, n, a string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, n, direct)
	}
	if _, err := h.StartHTTP(0); err == nil {
		t.Fatal("front started before the entry has a password")
	}
	_, pass, err := h.Start(0)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Stop()
	front, err := h.StartHTTP(0)
	if err != nil {
		t.Fatal(err)
	}
	defer h.StopHTTP()
	if again, _ := h.StartHTTP(0); again != front {
		t.Fatalf("StartHTTP not idempotent: %s vs %s", again, front)
	}

	// No credentials: a challenge (what WebView waits for), not a tunnel.
	if code, chal := connectVia(t, front, "", "example.com:443", "x"); code != 407 || !strings.HasPrefix(chal, "Basic") {
		t.Fatalf("no auth: %d %q", code, chal)
	}
	// Wrong password (another app): refused.
	if code, _ := connectVia(t, front, basic("default", "nope"), "example.com:443", "x"); code != 407 {
		t.Fatalf("wrong password: %d", code)
	}
	// Right password: direct route.
	if code, got := connectVia(t, front, basic("default", pass), "example.com:443", "hi"); code != 200 || got != "direct:hi" {
		t.Fatalf("direct: %d %q", code, got)
	}
	// A tailnet name goes through the tailnet whatever the route, host kept.
	if code, got := connectVia(t, front, basic("prov:abc", pass), "nas.tail1234.ts.net:22", "hi"); code != 200 || got != "tailnet:hi" {
		t.Fatalf("tailnet: %d %q", code, got)
	}
	if last := ts.dials[len(ts.dials)-1]; last != "nas.tail1234.ts.net:22" {
		t.Fatalf("tailnet dial lost the host name: %s", last)
	}

	// Plain HTTP absolute-form is forwarded in origin form.
	origin, _ := net.Listen("tcp", "127.0.0.1:0")
	defer origin.Close()
	gotLine := make(chan string, 1)
	go func() {
		c, err := origin.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		r, _ := http.ReadRequest(bufio.NewReader(c))
		gotLine <- r.RequestURI + "|" + r.Header.Get("Proxy-Authorization")
		io.WriteString(c, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
	}()
	h.dialDirect = func(ctx context.Context, n, a string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, n, origin.Addr().String())
	}
	c, _ := net.Dial("tcp", front)
	defer c.Close()
	fmt.Fprintf(c, "GET http://example.com/a?b=1 HTTP/1.1\r\nHost: example.com\r\nProxy-Authorization: %s\r\n\r\n", basic("browser", pass))
	resp, err := http.ReadResponse(bufio.NewReader(c), nil)
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("plain http: %v %v", err, resp)
	}
	if l := <-gotLine; l != "/a?b=1|" {
		t.Fatalf("origin saw %q (want origin form, no proxy credentials)", l)
	}

	// A failed dial is a 502 with the stage in the body, not a hang.
	h.dialDirect = func(ctx context.Context, n, a string) (net.Conn, error) { return nil, fmt.Errorf("connection refused") }
	if code, _ := connectVia(t, front, basic("default", pass), "example.com:443", "x"); code != 502 {
		t.Fatalf("failed dial: %d", code)
	}

	h.StopHTTP()
	if h.HTTPAddr() != "" {
		t.Fatal("still listening after StopHTTP")
	}
}

// A dial slower than the handshake limit still ends in a 502, not a dropped
// connection (the front clears the handshake deadline before dialing).
func TestHTTPFrontSlowDialAnswers502(t *testing.T) {
	if testing.Short() {
		t.Skip("waits past the 10 s handshake limit")
	}
	h := New(newFake(), nil)
	h.Configure(Config{DefaultRoute: "direct"})
	h.dialDirect = func(ctx context.Context, n, a string) (net.Conn, error) {
		select {
		case <-time.After(handshakeLimit + time.Second):
		case <-ctx.Done():
		}
		return nil, fmt.Errorf("i/o timeout")
	}
	_, pass, _ := h.Start(0)
	defer h.Stop()
	front, _ := h.StartHTTP(0)
	defer h.StopHTTP()
	if code, _ := connectVia(t, front, basic("default", pass), "example.com:443", "x"); code != 502 {
		t.Fatalf("slow dial: %d", code)
	}
}

