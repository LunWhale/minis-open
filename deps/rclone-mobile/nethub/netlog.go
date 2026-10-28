package nethub

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Diagnostic logging for the network module. Every line starts with "[Net]"
// plus a stage tag, so a user log shows WHICH segment of
//
//	policy -> entry -> (tailnet | upstream proxy | direct) -> target
//
// failed, and why:
//
//	[Net][Policy]  route decision: tag, host, rule, exit
//	[Net][Entry]   the local SOCKS5 entry: listen/stop, auth and handshake errors
//	[Net][Proxy]   upstream proxies: connect time, CONNECT / SOCKS replies, failure class
//	[Net][Dial]    connections through the tailnet or direct: time, failure class
//
// A short connection id (c0001...) ties the lines of one connection together.
// Secrets (entry password, proxy passwords) are never formatted into a line.
// Successful decisions are rate-limited per key; failures are always logged
// but capped per class so a dead target cannot flood the log.

var connSeq atomic.Uint32

func nextConnID() string { return fmt.Sprintf("c%04x", connSeq.Add(1)&0xffff) }

// limiter allows one event per key per interval.
type limiter struct {
	mu    sync.Mutex
	last  map[string]time.Time
	every time.Duration
	max   int // entries kept before the map is reset (bounded memory)
}

func newLimiter(every time.Duration) *limiter {
	return &limiter{last: map[string]time.Time{}, every: every, max: 512}
}

func (l *limiter) allow(key string) bool {
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	if t, ok := l.last[key]; ok && now.Sub(t) < l.every {
		return false
	}
	if len(l.last) >= l.max {
		l.last = map[string]time.Time{}
	}
	l.last[key] = now
	return true
}

// Failure classes, stable strings for grep and for the diagnose screen.
const (
	ClassTimeout     = "timeout"
	ClassDNS         = "dns"
	ClassRefused     = "refused"
	ClassUnreachable = "unreachable"
	ClassProxyAuth   = "proxy-auth"
	ClassProxyReject = "proxy-rejected"
	ClassTLS         = "tls"
	ClassClosed      = "closed"
	ClassOther       = "other"
)

// StageError carries where a connection failed and a failure class.
// Stages: tailnet, direct, proxy-connect, proxy-tls, proxy-handshake, proxy-target.
type StageError struct {
	Stage string
	Class string
	Err   error
}

func (e *StageError) Error() string { return e.Stage + "/" + e.Class + ": " + e.Err.Error() }
func (e *StageError) Unwrap() error { return e.Err }

func stageErr(stage string, err error) error {
	if err == nil {
		return nil
	}
	var se *StageError
	if errors.As(err, &se) {
		return err
	}
	return &StageError{Stage: stage, Class: Classify(err), Err: err}
}

// Classify maps an error to a failure class.
func Classify(err error) string {
	if err == nil {
		return ""
	}
	var se *StageError
	if errors.As(err, &se) {
		return se.Class
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return ClassTimeout
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return ClassTimeout
	}
	var de *net.DNSError
	if errors.As(err, &de) {
		return ClassDNS
	}
	msg := strings.ToLower(err.Error())
	switch {
	case strings.Contains(msg, "407"), strings.Contains(msg, "authentication failed"),
		strings.Contains(msg, "authentication required"):
		return ClassProxyAuth
	case strings.Contains(msg, "no such host"), strings.Contains(msg, "lookup "):
		return ClassDNS
	case strings.Contains(msg, "refused"):
		return ClassRefused
	case strings.Contains(msg, "unreachable"), strings.Contains(msg, "no route to host"),
		strings.Contains(msg, "host is down"):
		return ClassUnreachable
	case strings.Contains(msg, "x509"), strings.Contains(msg, "tls:"), strings.Contains(msg, "certificate"):
		return ClassTLS
	case strings.Contains(msg, "proxy connect"), strings.Contains(msg, "socks connect"),
		strings.Contains(msg, "general socks server failure"), strings.Contains(msg, "connection not allowed"):
		return ClassProxyReject
	case strings.Contains(msg, "timeout"), strings.Contains(msg, "deadline"):
		return ClassTimeout
	case strings.Contains(msg, "closed"), strings.Contains(msg, "reset by peer"), strings.Contains(msg, "eof"):
		return ClassClosed
	}
	return ClassOther
}

// Stage of an error, "" if none recorded.
func Stage(err error) string {
	var se *StageError
	if errors.As(err, &se) {
		return se.Stage
	}
	return ""
}
