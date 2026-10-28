package nethub

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strconv"
	"strings"
	"time"
)

// Minimal SOCKS5 server (RFC 1928 CONNECT + RFC 1929 username/password).
// UDP ASSOCIATE is served for iSH's transparent forwarding (udp.go); BIND is
// refused. Written here instead of reusing tailscale's socks5.Server
// because the route depends on the USERNAME of each connection.

const (
	socksVer       = 5
	methodUserPass = 2
	methodNone     = 0xFF
	cmdConnect     = 1
	atypIPv4       = 1
	atypDomain     = 3
	atypIPv6       = 4
	repSuccess     = 0
	repGeneralFail = 1
	repNotAllowed  = 2
	repNetUnreach  = 3
	repHostUnreach = 4
	repConnRefused = 5
	repCmdNotSupp  = 7
	repAddrNotSupp = 8
	handshakeLimit = 10 * time.Second
	// connectDeadline bounds the whole connect phase (DNS, TCP, proxy
	// handshake, CONNECT reply) so a broken route fails with a clear error
	// instead of hanging.
	connectDeadline = 15 * time.Second
)

func (h *Hub) serve(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			// Closed by Stop -> h.ln was already cleared and this is a no-op;
			// anything else means the socket died under us (iOS can reclaim
			// sockets of a suspended app). Either way this loop ends.
			h.listenerDied(ln, err)
			return
		}
		go h.handle(c)
	}
}

func (h *Hub) handle(c net.Conn) {
	defer c.Close()
	id := nextConnID()
	c.SetDeadline(time.Now().Add(handshakeLimit))
	tag, err := h.negotiate(c)
	if err != nil {
		if h.entryLog.allow("auth:" + Classify(err)) {
			if errors.Is(err, errAuth) {
				h.logf("[Net][Entry] %s rejected: wrong entry password or no auth offered (another app?)", id)
			} else {
				h.logf("[Net][Entry] %s handshake error: %v", id, err)
			}
		}
		return
	}
	// [FEAT-261020-07] iSH's transparent forwarding authenticates as
	// "<tag>~x<id>": route by the tag, and log under iSH's id too, so a
	// "[Net][Xparent] x1f" line and its "[Net]" lines here can be matched.
	tag, clientID := SplitTag(tag)
	if tag == "" {
		tag = "default"
	}
	// "~dns" (after the id, or alone) marks iSH's intercepted DNS (dns.go).
	clientID, dns := strings.CutSuffix(clientID, "~dns")
	if clientID == "dns" {
		clientID, dns = "", true
	}
	if clientID != "" {
		id += "~" + clientID
	}
	if dns {
		id += "~dns"
	}
	cmd, host, port, err := readRequest(c)
	if err != nil {
		var re replyError
		if errors.As(err, &re) {
			writeReply(c, re.code)
		}
		if h.entryLog.allow("req:" + Classify(err)) {
			h.logf("[Net][Entry] %s tag=%s bad request: %v", id, tag, err)
		}
		return
	}
	c.SetDeadline(time.Time{})
	if cmd == cmdUDPAssociate {
		h.serveAssociate(c, id, tag, dns, host, port)
		return
	}
	addr := net.JoinHostPort(host, strconv.Itoa(port))
	if dns {
		h.serveDNSTCP(c, id, tag, addr)
		return
	}
	d := h.Decide(tag, host)
	if h.policyLog.allow(tag + "|" + addr + "|" + d.Exit()) {
		h.logf("[Net][Policy] %s tag=%s host=%s rule=%s route=%s exit=%s", id, tag, addr, d.Rule, d.Route, d.Exit())
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
		writeReply(c, replyCodeFor(err))
		return
	}
	defer out.Close()
	if h.okLog.allow(d.Exit() + "|" + addr) {
		h.logSuccess(id, addr, d, ms)
	}
	if err := writeReply(c, repSuccess); err != nil {
		return
	}
	h.active.Add(1)
	pipe(c, out)
	h.active.Add(-1)
}

// logFailure: one line naming the stage that failed and the class.
func (h *Hub) logFailure(id, tag, addr string, d Decision, ms int64, err error) {
	class, stage := Classify(err), Stage(err)
	if !h.failLog.allow(stage + "|" + class + "|" + addr) {
		return
	}
	switch d.Kind {
	case "tailscale":
		peer := h.describePeer(hostOf(addr))
		h.logf("[Net][Dial] %s FAIL stage=tailnet target=%s class=%s after %dms peer=%s tag=%s: %v",
			id, addr, class, ms, orNone(peer), tag, err)
	case "proxy":
		h.logf("[Net][Proxy] %s FAIL stage=%s via=%s target=%s class=%s after %dms tag=%s: %v",
			id, stage, d.Exit(), addr, class, ms, tag, err)
	default:
		h.logf("[Net][Dial] %s FAIL stage=direct target=%s class=%s after %dms tag=%s: %v",
			id, addr, class, ms, tag, err)
	}
}

func (h *Hub) logSuccess(id, addr string, d Decision, ms int64) {
	switch d.Kind {
	case "tailscale":
		h.logf("[Net][Dial] %s ok tailnet target=%s in %dms peer=%s", id, addr, ms, orNone(h.describePeer(hostOf(addr))))
	case "proxy":
		h.logf("[Net][Proxy] %s ok via=%s target=%s in %dms", id, d.Exit(), addr, ms)
	}
	// direct successes are not logged (the common, unchanged path).
}

func hostOf(addr string) string {
	if h, _, err := net.SplitHostPort(addr); err == nil {
		return h
	}
	return addr
}

func orNone(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func (h *Hub) negotiate(c net.Conn) (tag string, err error) {
	var hdr [2]byte
	if _, err = io.ReadFull(c, hdr[:]); err != nil || hdr[0] != socksVer {
		return "", errors.New("bad version")
	}
	methods := make([]byte, hdr[1])
	if _, err = io.ReadFull(c, methods); err != nil {
		return "", err
	}
	offered := false
	for _, m := range methods {
		if m == methodUserPass {
			offered = true
		}
	}
	if !offered {
		c.Write([]byte{socksVer, methodNone})
		return "", errAuth
	}
	if _, err = c.Write([]byte{socksVer, methodUserPass}); err != nil {
		return "", err
	}
	// RFC 1929: VER=1, ULEN, UNAME, PLEN, PASSWD
	var v [2]byte
	if _, err = io.ReadFull(c, v[:]); err != nil || v[0] != 1 {
		return "", errors.New("bad auth version")
	}
	user := make([]byte, v[1])
	if _, err = io.ReadFull(c, user); err != nil {
		return "", err
	}
	var pl [1]byte
	if _, err = io.ReadFull(c, pl[:]); err != nil {
		return "", err
	}
	pass := make([]byte, pl[0])
	if _, err = io.ReadFull(c, pass); err != nil {
		return "", err
	}
	h.mu.RLock()
	want := h.password
	h.mu.RUnlock()
	if want == "" || string(pass) != want {
		c.Write([]byte{1, 1})
		return "", errAuth
	}
	if _, err = c.Write([]byte{1, 0}); err != nil {
		return "", err
	}
	tag = string(user)
	if tag == "" {
		tag = "default"
	}
	return tag, nil
}

type replyError struct{ code byte }

func (e replyError) Error() string { return "socks reply " + strconv.Itoa(int(e.code)) }

func readRequest(c net.Conn) (cmd byte, host string, port int, err error) {
	var hdr [4]byte
	if _, err = io.ReadFull(c, hdr[:]); err != nil {
		return
	}
	if hdr[0] != socksVer {
		return 0, "", 0, errors.New("bad version")
	}
	cmd = hdr[1]
	if cmd != cmdConnect && cmd != cmdUDPAssociate {
		return 0, "", 0, replyError{repCmdNotSupp}
	}
	switch hdr[3] {
	case atypIPv4:
		var b [4]byte
		if _, err = io.ReadFull(c, b[:]); err != nil {
			return
		}
		host = net.IP(b[:]).String()
	case atypIPv6:
		var b [16]byte
		if _, err = io.ReadFull(c, b[:]); err != nil {
			return
		}
		host = net.IP(b[:]).String()
	case atypDomain:
		var l [1]byte
		if _, err = io.ReadFull(c, l[:]); err != nil {
			return
		}
		b := make([]byte, l[0])
		if _, err = io.ReadFull(c, b); err != nil {
			return
		}
		host = string(b)
	default:
		return 0, "", 0, replyError{repAddrNotSupp}
	}
	var p [2]byte
	if _, err = io.ReadFull(c, p[:]); err != nil {
		return
	}
	return cmd, host, int(binary.BigEndian.Uint16(p[:])), nil
}

func writeReply(c net.Conn, code byte) error {
	// BND.ADDR is not meaningful for clients here; 0.0.0.0:0.
	_, err := c.Write([]byte{socksVer, code, 0, atypIPv4, 0, 0, 0, 0, 0, 0})
	return err
}

func replyCodeFor(err error) byte {
	var oe *net.OpError
	if errors.As(err, &oe) {
		msg := oe.Err.Error()
		switch {
		case containsAny(msg, "refused"):
			return repConnRefused
		case containsAny(msg, "network is unreachable"):
			return repNetUnreach
		case containsAny(msg, "no route", "host is down", "no such host"):
			return repHostUnreach
		}
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return repHostUnreach
	}
	return repGeneralFail
}

func containsAny(s string, subs ...string) bool {
	for _, x := range subs {
		if strings.Contains(s, x) {
			return true
		}
	}
	return false
}

func pipe(a, b net.Conn) {
	done := make(chan struct{}, 2)
	cp := func(dst, src net.Conn) {
		io.Copy(dst, src)
		if tc, ok := dst.(interface{ CloseWrite() error }); ok {
			tc.CloseWrite()
		} else {
			dst.Close()
		}
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	<-done
}
