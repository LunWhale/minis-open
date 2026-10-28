// Package netfs serves one rclone remote as a read-only filesystem for the
// iSH kernel's netfs.
//
// Every operation is bounded: it runs on its own goroutine under a deadline,
// and the caller gets an answer when the work finishes or the deadline passes,
// whichever is first. A backend that ignores its context keeps its goroutine,
// but each mount runs at most Config.MaxConcurrent of them, so the leak is
// bounded and one stuck mount cannot slow another.
package netfs

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
	"syscall"

	"github.com/rclone/rclone/backend/webdav/api"
	"github.com/rclone/rclone/fs"
)

// Linux errno values, as the guest sees them (not the host's numbering).
const (
	EINTR        = 4
	EIO          = 5
	EACCES       = 13
	ENOENT       = 2
	ENOTDIR      = 20
	EISDIR       = 21
	EINVAL       = 22
	EROFS        = 30
	ENOTCONN     = 107
	ETIMEDOUT    = 110
	ECONNREFUSED = 111
	EHOSTUNREACH = 113
	ESTALE       = 116
	EREMOTEIO    = 121
)

// Cause is why a network operation failed. The breaker remembers the last
// one, so a request refused while the mount is offline reports the reason the
// mount went offline (design §7-2), not a generic "unreachable".
type Cause int

const (
	CauseNone     Cause = iota
	CauseTimeout        // deadline, queue wait or budget
	CauseConnect        // DNS, no route, dial timeout
	CauseRefused        // connection refused
	CauseServer         // HTTP 5xx and the like
	CauseAuth           // 401, bad login
	CauseNotFound       // not a failure of the mount
	CauseOther
	CauseCert // TLS certificate not trusted, or not the fingerprint the user trusted
	// CauseForbidden is a 403 on one path: the server answered and the login
	// works, the user just may not read THAT path (a Nextcloud/Synology share
	// rule, an S3 bucket policy). Like not-found it is not a failure of the
	// mount. [T-netmount-403-per-path]: it used to count as CauseAuth, which
	// latched the whole disk "login failed" because of one forbidden folder.
	CauseForbidden
)

func (c Cause) String() string {
	return [...]string{"none", "timeout", "connect", "refused", "server", "auth", "not-found", "other", "certificate", "forbidden"}[c]
}

// Errno for a failure of this cause.
func (c Cause) Errno() int {
	switch c {
	case CauseTimeout:
		return ETIMEDOUT
	case CauseConnect:
		return EHOSTUNREACH
	case CauseRefused:
		return ECONNREFUSED
	case CauseServer:
		return EREMOTEIO
	case CauseAuth, CauseCert, CauseForbidden:
		return EACCES
	case CauseNotFound:
		return ENOENT
	default:
		return EIO
	}
}

// Error is what every operation returns on failure.
type Error struct {
	Errno int
	Cause Cause
	Msg   string
}

func (e *Error) Error() string { return fmt.Sprintf("errno %d (%s): %s", e.Errno, e.Cause, e.Msg) }

func newErr(errno int, cause Cause, msg string) *Error {
	return &Error{Errno: errno, Cause: cause, Msg: msg}
}

// classify maps a backend error to its cause.
func classify(err error) Cause {
	if err == nil {
		return CauseNone
	}
	if errors.Is(err, fs.ErrorObjectNotFound) || errors.Is(err, fs.ErrorDirNotFound) || errors.Is(err, os.ErrNotExist) {
		return CauseNotFound
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, os.ErrDeadlineExceeded) {
		return CauseTimeout
	}
	var apiErr *api.Error
	if errors.As(err, &apiErr) {
		switch {
		case apiErr.StatusCode == 401:
			return CauseAuth
		case apiErr.StatusCode == 403:
			return CauseForbidden
		case apiErr.StatusCode == 404:
			return CauseNotFound
		case apiErr.StatusCode >= 500:
			return CauseServer
		}
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		return CauseRefused
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return CauseConnect
	}
	var opErr *net.OpError
	if errors.As(err, &opErr) {
		if opErr.Timeout() {
			if opErr.Op == "dial" {
				return CauseConnect
			}
			return CauseTimeout
		}
		if opErr.Op == "dial" {
			return CauseConnect
		}
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return CauseTimeout
	}
	// Some backends only say it in text.
	msg := strings.ToLower(err.Error())
	switch {
	case strings.Contains(msg, "401 unauthorized"),
		strings.Contains(msg, "logon failure"), strings.Contains(msg, "unable to authenticate"),
		// S3 answers a wrong key or secret with 403 too; these codes name a
		// bad login, not a forbidden path.
		strings.Contains(msg, "invalidaccesskeyid"), strings.Contains(msg, "signaturedoesnotmatch"),
		strings.Contains(msg, "invalidtoken"), strings.Contains(msg, "expiredtoken"):
		return CauseAuth
	case strings.Contains(msg, "403 forbidden"), strings.Contains(msg, "accessdenied"):
		return CauseForbidden
	case strings.Contains(msg, "connection refused"):
		return CauseRefused
	case strings.Contains(msg, "no route to host"), strings.Contains(msg, "network is unreachable"):
		return CauseConnect
	case strings.Contains(msg, "timeout"):
		return CauseTimeout
	}
	return CauseOther
}
