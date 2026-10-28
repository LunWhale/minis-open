package nethub

import (
	"bufio"
	"context"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// HTTP proxy front of the local entry, for clients that cannot do SOCKS5 with
// per-connection credentials:
//   - OkHttp on Android: Java's SOCKS support takes credentials only from a
//     process-wide java.net.Authenticator, so a per-tag username is
//     impossible; an HTTP proxy with a Basic Proxy-Authorization (sent
//     preemptively by OkHttp for CONNECT) is per client.
//   - Android WebView: Chromium cannot authenticate to a SOCKS proxy at all;
//     it answers an HTTP proxy's 407 through onReceivedHttpAuthRequest.
//
// Same password, same policy (Decide) and same dialer as the SOCKS entry;
// the Basic username is the policy tag. CONNECT tunnels keep the host name
// (remote DNS, so MagicDNS names resolve through the route); plain-HTTP
// absolute-form requests are forwarded one per connection.

type httpFront struct {
	mu sync.Mutex
	ln net.Listener
}

// One front per hub; kept outside Hub so this file adds no field to it.
var httpFronts sync.Map // *Hub -> *httpFront

func (h *Hub) front() *httpFront {
	f, _ := httpFronts.LoadOrStore(h, &httpFront{})
	return f.(*httpFront)
}

// StartHTTP listens on 127.0.0.1 (port 0 = any) for HTTP proxy clients.
// Idempotent. Start must have run first (it creates the password).
func (h *Hub) StartHTTP(port int) (string, error) {
	h.mu.RLock()
	ready := h.password != ""
	h.mu.RUnlock()
	if !ready {
		return "", errors.New("nethub: start the entry before its HTTP front")
	}
	f := h.front()
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.ln != nil {
		return f.ln.Addr().String(), nil
	}
	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return "", err
	}
	f.ln = ln
	go h.serveHTTP(f, ln)
	h.logf("[Net][Entry] http front listening on %s", ln.Addr())
	return ln.Addr().String(), nil
}

// StopHTTP closes the HTTP front.
func (h *Hub) StopHTTP() {
	f := h.front()
	f.mu.Lock()
	ln := f.ln
	f.ln = nil
	f.mu.Unlock()
	if ln != nil {
		ln.Close()
		h.logf("[Net][Entry] http front stopped (was %s)", ln.Addr())
	}
}

// HTTPAddr is the front's address, "" when it is not listening.
func (h *Hub) HTTPAddr() string {
	f := h.front()
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.ln == nil {
		return ""
	}
	return f.ln.Addr().String()
}

func (h *Hub) serveHTTP(f *httpFront, ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			f.mu.Lock()
			if f.ln == ln { // died without StopHTTP: forget it so the next StartHTTP reopens
				f.ln = nil
				h.logf("[Net][Entry] http front %s died: %v", ln.Addr(), err)
			}
			f.mu.Unlock()
			return
		}
		go h.handleHTTP(c)
	}
}

// proxyTag checks Proxy-Authorization and returns the tag (Basic username).
func (h *Hub) proxyTag(r *http.Request) (string, bool) {
	v := r.Header.Get("Proxy-Authorization")
	const p = "Basic "
	if len(v) < len(p) || !strings.EqualFold(v[:len(p)], p) {
		return "", false
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(v[len(p):]))
	if err != nil {
		return "", false
	}
	// Split at the LAST colon: tags such as "prov:<id>" contain one, the
	// password (hex) never does.
	i := strings.LastIndexByte(string(raw), ':')
	ok := i > 0
	user, pass := "", ""
	if ok {
		user, pass = string(raw[:i]), string(raw[i+1:])
	}
	h.mu.RLock()
	want := h.password
	h.mu.RUnlock()
	if !ok || user == "" || want == "" || subtle.ConstantTimeCompare([]byte(pass), []byte(want)) != 1 {
		return "", false
	}
	// Same "<tag>~<id>" convention as the SOCKS entry; HTTP clients have no
	// reason to send it, so the id is dropped.
	tag, _ := SplitTag(user)
	if tag == "" {
		return "", false
	}
	return tag, true
}

func writeHTTPStatus(c net.Conn, code int, extra, body string) {
	fmt.Fprintf(c, "HTTP/1.1 %d %s\r\n%sContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		code, http.StatusText(code), extra, len(body), body)
}

func (h *Hub) handleHTTP(c net.Conn) {
	defer c.Close()
	id := nextConnID()
	c.SetDeadline(time.Now().Add(handshakeLimit))
	br := bufio.NewReader(c)
	req, err := http.ReadRequest(br)
	if err != nil {
		return
	}
	tag, ok := h.proxyTag(req)
	if !ok {
		// Expected once per WebView connection (Chromium waits for the
		// challenge); a wrong password means another app.
		if req.Header.Get("Proxy-Authorization") != "" && h.entryLog.allow("http-auth") {
			h.logf("[Net][Entry] %s http rejected: wrong entry password (another app?)", id)
		}
		writeHTTPStatus(c, http.StatusProxyAuthRequired, "Proxy-Authenticate: Basic realm=\"Minis\"\r\n", "")
		return
	}
	connect := req.Method == http.MethodConnect
	hostport := req.Host
	if !connect && req.URL != nil && req.URL.Host != "" {
		hostport = req.URL.Host
	}
	host, port, err := net.SplitHostPort(hostport)
	if err != nil {
		host, port = hostport, "80"
		if connect {
			port = "443"
		}
	}
	addr := net.JoinHostPort(host, port)
	// The handshake deadline ends here, as in the SOCKS entry: a slow dial
	// (an offline peer takes the whole connectDeadline) must still be able to
	// answer 502 instead of the client seeing the connection drop.
	c.SetDeadline(time.Time{})
	d := h.Decide(tag, host)
	if h.policyLog.allow(tag + "|" + addr + "|" + d.Exit()) {
		h.logf("[Net][Policy] %s http tag=%s host=%s rule=%s route=%s exit=%s", id, tag, addr, d.Rule, d.Route, d.Exit())
	}
	ctx, cancel := context.WithTimeout(context.Background(), connectDeadline)
	t0 := time.Now()
	out, err := h.dial(ctx, d, addr)
	cancel()
	ms := time.Since(t0).Milliseconds()
	h.conns.Add(1)
	h.recordExit(d, err)
	if err != nil {
		h.failures.Add(1)
		h.logFailure(id, tag, addr, d, ms, err)
		writeHTTPStatus(c, http.StatusBadGateway, "", "minis entry: "+err.Error())
		return
	}
	defer out.Close()
	if h.okLog.allow(d.Exit() + "|" + addr) {
		h.logSuccess(id, addr, d, ms)
	}
	h.active.Add(1)
	defer h.active.Add(-1)
	if connect {
		if _, err := c.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
			return
		}
		// Bytes the client sent right after CONNECT (TLS ClientHello) may
		// already sit in the reader.
		if n := br.Buffered(); n > 0 {
			b, _ := br.Peek(n)
			if _, err := out.Write(b); err != nil {
				return
			}
			br.Discard(n)
		}
		pipe(c, out)
		return
	}
	// Plain HTTP: forward this one request in origin form, then relay.
	req.Header.Del("Proxy-Authorization")
	req.Header.Del("Proxy-Connection")
	req.RequestURI = ""
	req.Close = true
	if err := req.Write(out); err != nil {
		return
	}
	pipe(c, out)
}
