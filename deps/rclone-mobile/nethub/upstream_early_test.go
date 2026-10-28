package nethub

import (
	"bufio"
	"context"
	"io"
	"net"
	"net/http"
	"strconv"
	"testing"
	"time"
)

// [FEAT-261021-14] A server that speaks first (SSH) answers as soon as the
// proxy connects it, and the proxy relays that with its "200" in one write.
// The bytes belong to the tunnel; the dial must succeed and hand them over.
func TestHTTPConnectKeepsEarlyTunnelBytes(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		if _, err := http.ReadRequest(bufio.NewReader(c)); err != nil {
			return
		}
		c.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\nSSH-2.0-test\r\n"))
		io.Copy(io.Discard, c)
	}()
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	p, _ := strconv.Atoi(port)
	c, err := DialUpstream(context.Background(), &net.Dialer{Timeout: time.Second},
		Upstream{Type: "http", Host: "127.0.0.1", Port: p}, "10.0.0.1:22")
	if err != nil {
		t.Fatalf("dial failed: %v", err)
	}
	defer c.Close()
	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	line, err := bufio.NewReader(c).ReadString('\n')
	if err != nil || line != "SSH-2.0-test\r\n" {
		t.Fatalf("first read = %q, %v", line, err)
	}
	if _, ok := c.(interface{ CloseWrite() error }); !ok {
		t.Fatal("tunnel lost CloseWrite (half-close for relays)")
	}
}

// Nothing early: the plain connection comes back unchanged.
func TestHTTPConnectWithoutEarlyBytesIsThePlainConn(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		http.ReadRequest(bufio.NewReader(c))
		c.Write([]byte("HTTP/1.1 200 OK\r\n\r\n"))
		io.Copy(io.Discard, c)
	}()
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	p, _ := strconv.Atoi(port)
	c, err := DialUpstream(context.Background(), &net.Dialer{Timeout: time.Second},
		Upstream{Type: "http", Host: "127.0.0.1", Port: p}, "10.0.0.1:443")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if _, wrapped := c.(*prefixConn); wrapped {
		t.Fatal("wrapped without early bytes")
	}
}
