package nethub

import (
	"bufio"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"

	"golang.org/x/net/proxy"
)

// Building blocks of the "network diagnose" screen. Each returns how long
// the check took and an error carrying a stage and class when it fails.

// SelfTest proves the local entry end to end: TCP accept, RFC 1929 auth with
// the entry password, CONNECT, and relaying bytes. The target is a throwaway
// loopback listener, and loopback always bypasses routes, so the result does
// not depend on the user's routing settings.
func (h *Hub) SelfTest(timeout time.Duration) (time.Duration, error) {
	h.mu.RLock()
	ln, pass := h.ln, h.password
	h.mu.RUnlock()
	if ln == nil || h.dead.Load() {
		return 0, &StageError{Stage: "entry", Class: ClassClosed, Err: errors.New("local entry is not listening")}
	}
	target, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, &StageError{Stage: "entry", Class: ClassOther, Err: err}
	}
	defer target.Close()
	go func() {
		c, err := target.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		io.WriteString(c, "ok\n")
	}()
	t0 := time.Now()
	d, err := proxy.SOCKS5("tcp", ln.Addr().String(), &proxy.Auth{User: "diagnose", Password: pass},
		&net.Dialer{Timeout: timeout})
	if err != nil {
		return 0, &StageError{Stage: "entry", Class: ClassOther, Err: err}
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	c, err := d.(proxy.ContextDialer).DialContext(ctx, "tcp", target.Addr().String())
	if err != nil {
		return 0, &StageError{Stage: "entry", Class: Classify(err), Err: err}
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(timeout))
	line, err := bufio.NewReader(c).ReadString('\n')
	if err != nil || line != "ok\n" {
		if err == nil {
			err = errors.New("relay returned unexpected data")
		}
		return 0, &StageError{Stage: "entry", Class: Classify(err), Err: err}
	}
	return time.Since(t0), nil
}

// HTTPSelfTest proves the entry's HTTP proxy front the same way: TCP accept,
// Basic Proxy-Authorization with the entry password, CONNECT, and relaying
// bytes to a throwaway loopback listener. The password is never part of the
// returned error.
func (h *Hub) HTTPSelfTest(timeout time.Duration) (time.Duration, error) {
	h.mu.RLock()
	pass := h.password
	h.mu.RUnlock()
	addr := h.HTTPAddr()
	if addr == "" || pass == "" {
		return 0, &StageError{Stage: "entry", Class: ClassClosed, Err: errors.New("http front is not listening")}
	}
	target, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, &StageError{Stage: "entry", Class: ClassOther, Err: err}
	}
	defer target.Close()
	go func() {
		c, err := target.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		io.WriteString(c, "ok\n")
	}()
	t0 := time.Now()
	c, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return 0, &StageError{Stage: "entry", Class: Classify(err), Err: err}
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(timeout))
	auth := base64.StdEncoding.EncodeToString([]byte("diagnose:" + pass))
	fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Authorization: Basic %s\r\n\r\n",
		target.Addr(), target.Addr(), auth)
	br := bufio.NewReader(c)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodConnect})
	if err != nil {
		return 0, &StageError{Stage: "entry", Class: Classify(err), Err: err}
	}
	if resp.StatusCode != http.StatusOK {
		return 0, &StageError{Stage: "entry", Class: ClassOther, Err: fmt.Errorf("http front answered %s", resp.Status)}
	}
	line, err := br.ReadString('\n')
	if err != nil || line != "ok\n" {
		if err == nil {
			err = errors.New("relay returned unexpected data")
		}
		return 0, &StageError{Stage: "entry", Class: Classify(err), Err: err}
	}
	return time.Since(t0), nil
}

// DirectProbe opens a plain TCP connection (DNS + connect), bypassing every
// route: is the device's own network working at all?
func DirectProbe(addr string, timeout time.Duration) (time.Duration, error) {
	t0 := time.Now()
	c, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return 0, stageErr("direct", err)
	}
	c.Close()
	return time.Since(t0), nil
}

// ResolveProbe looks a name up with the system resolver.
func ResolveProbe(name string, timeout time.Duration) (time.Duration, []string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	t0 := time.Now()
	addrs, err := net.DefaultResolver.LookupHost(ctx, name)
	if err != nil {
		return 0, nil, &StageError{Stage: "dns", Class: ClassDNS, Err: err}
	}
	return time.Since(t0), addrs, nil
}
