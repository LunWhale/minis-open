package nethub

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/base64"
	"net"
	"net/http"
	"strconv"
	"sync/atomic"
	"time"

	"golang.org/x/net/proxy"
)

// DialUpstream connects to addr through the user's proxy u. Errors are
// *StageError naming the failed segment:
//
//	proxy-connect    TCP (or DNS) to the proxy itself
//	proxy-tls        TLS to an HTTPS proxy
//	proxy-handshake  the proxy refused us (407 / SOCKS auth) or broke the handshake
//	proxy-target     the proxy answered but could not reach the target
func DialUpstream(ctx context.Context, base *net.Dialer, u Upstream, addr string) (net.Conn, error) {
	proxyAddr := net.JoinHostPort(u.Host, strconv.Itoa(u.Port))
	switch u.Type {
	case "socks5":
		var auth *proxy.Auth
		if u.Username != "" || u.Password != "" {
			auth = &proxy.Auth{User: u.Username, Password: u.Password}
		}
		fwd := &recordingDialer{base: base}
		d, err := proxy.SOCKS5("tcp", proxyAddr, auth, fwd)
		if err != nil {
			return nil, stageErr("proxy-connect", err)
		}
		c, err := d.(proxy.ContextDialer).DialContext(ctx, "tcp", addr)
		if err != nil {
			switch {
			case !fwd.connected.Load():
				return nil, stageErr("proxy-connect", err)
			case Classify(err) == ClassProxyAuth:
				return nil, &StageError{Stage: "proxy-handshake", Class: ClassProxyAuth, Err: err}
			case Classify(err) == ClassTimeout:
				return nil, &StageError{Stage: "proxy-handshake", Class: ClassTimeout, Err: err}
			default:
				return nil, &StageError{Stage: "proxy-target", Class: ClassProxyReject, Err: err}
			}
		}
		return c, nil
	case "http", "https":
		c, err := base.DialContext(ctx, "tcp", proxyAddr)
		if err != nil {
			return nil, stageErr("proxy-connect", err)
		}
		if u.Type == "https" {
			tc := tls.Client(c, &tls.Config{ServerName: u.Host})
			if err := tc.HandshakeContext(ctx); err != nil {
				c.Close()
				return nil, &StageError{Stage: "proxy-tls", Class: ClassTLS, Err: err}
			}
			c = tc
		}
		tc, err := httpConnect(ctx, c, u, addr)
		if err != nil {
			c.Close()
			return nil, err
		}
		return tc, nil
	}
	return nil, &StageError{Stage: "proxy-connect", Class: ClassOther, Err: fmtErr("unknown proxy type %q", u.Type)}
}

// recordingDialer remembers whether the TCP connection to the proxy itself
// succeeded, which separates "proxy unreachable" from "proxy refused".
type recordingDialer struct {
	base      *net.Dialer
	connected atomic.Bool
}

func (r *recordingDialer) Dial(network, addr string) (net.Conn, error) {
	return r.DialContext(context.Background(), network, addr)
}

func (r *recordingDialer) DialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	c, err := r.base.DialContext(ctx, network, addr)
	if err == nil {
		r.connected.Store(true)
	}
	return c, err
}

// httpConnect issues CONNECT addr and reads the response; the connection is
// then a raw tunnel.
//
// [FEAT-261021-14] Bytes that arrive with the response belong to the
// tunnel: a server that speaks first (SSH's version banner, FTP's 220
// greeting, SMTP) answers as soon as the proxy connects it, and a proxy may
// relay that in the same segment as "200". They used to fail the connection
// ("proxy sent data before the tunnel was ready"), which broke SFTP and FTP
// through HTTP proxies; now they are handed to the caller first.
func httpConnect(ctx context.Context, c net.Conn, u Upstream, addr string) (net.Conn, error) {
	if dl, ok := ctx.Deadline(); ok {
		c.SetDeadline(dl)
		defer c.SetDeadline(timeZero)
	}
	req := "CONNECT " + addr + " HTTP/1.1\r\nHost: " + addr + "\r\n"
	if u.Username != "" || u.Password != "" {
		cred := base64.StdEncoding.EncodeToString([]byte(u.Username + ":" + u.Password))
		req += "Proxy-Authorization: Basic " + cred + "\r\n"
	}
	req += "\r\n"
	if _, err := c.Write([]byte(req)); err != nil {
		return nil, stageErr("proxy-handshake", err)
	}
	br := bufio.NewReader(c)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodConnect})
	if err != nil {
		return nil, stageErr("proxy-handshake", err)
	}
	resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusProxyAuthRequired:
		return nil, &StageError{Stage: "proxy-handshake", Class: ClassProxyAuth,
			Err: fmtErr("proxy CONNECT %s: %s (wrong or missing proxy username/password)", addr, resp.Status)}
	case resp.StatusCode != http.StatusOK:
		return nil, &StageError{Stage: "proxy-target", Class: ClassProxyReject,
			Err: fmtErr("proxy CONNECT %s: %s", addr, resp.Status)}
	}
	if n := br.Buffered(); n > 0 {
		early, _ := br.Peek(n)
		return &prefixConn{Conn: c, prefix: append([]byte(nil), early...)}, nil
	}
	return c, nil
}

// prefixConn returns bytes already read from the tunnel before reading on.
type prefixConn struct {
	net.Conn
	prefix []byte
}

func (p *prefixConn) Read(b []byte) (int, error) {
	if len(p.prefix) > 0 {
		n := copy(b, p.prefix)
		p.prefix = p.prefix[n:]
		return n, nil
	}
	return p.Conn.Read(b)
}

// CloseWrite keeps half-close working for relays (pipe in socks.go).
func (p *prefixConn) CloseWrite() error {
	if cw, ok := p.Conn.(interface{ CloseWrite() error }); ok {
		return cw.CloseWrite()
	}
	return p.Conn.Close()
}

var timeZero time.Time
