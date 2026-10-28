package main

// C entry points for the embedded Tailscale node (deps/rclone-mobile/tsnet).
// Functions returning char* return a malloc'd JSON string the caller frees
// with MinisTsFreeString: {"ok":true[,"result":...]} or {"ok":false,"error":"..."}.

/*
#include <stdlib.h>

typedef void (*minis_ts_log_fn)(const char *line);
static void minis_ts_call_log(minis_ts_log_fn fn, const char *line) { if (fn) fn(line); }
*/
import "C"

import (
	"encoding/json"
	"sync"
	"time"
	"unsafe"

	"github.com/OpenMinis/minis-rclone/tsnet"
)

var (
	tsLogMu sync.Mutex
	tsLogFn C.minis_ts_log_fn
)

func tsResult(extra string, err error) *C.char {
	if err != nil {
		b, _ := json.Marshal(map[string]any{"ok": false, "error": err.Error()})
		return C.CString(string(b))
	}
	if extra != "" {
		return C.CString(`{"ok":true,"result":` + extra + `}`)
	}
	return C.CString(`{"ok":true}`)
}

// MinisTsSetLogger registers where the node's log lines go (the app forwards
// them to AppLogger). NULL turns logging off.
//
//export MinisTsSetLogger
func MinisTsSetLogger(fn C.minis_ts_log_fn) {
	tsLogMu.Lock()
	tsLogFn = fn
	tsLogMu.Unlock()
	if fn == nil {
		tsnet.SetLogger(nil)
		return
	}
	tsnet.SetLogger(func(line string) {
		tsLogMu.Lock()
		f := tsLogFn
		tsLogMu.Unlock()
		cs := C.CString(line)
		C.minis_ts_call_log(f, cs)
		C.free(unsafe.Pointer(cs))
	})
}

// MinisTsSetDefaultRouteInterface passes the OS default interface name (from
// NWPathMonitor, e.g. "en0" / "pdp_ip0") to the node's network monitor.
//
//export MinisTsSetDefaultRouteInterface
func MinisTsSetDefaultRouteInterface(ifName *C.char) {
	tsnet.SetDefaultRouteInterface(C.GoString(ifName))
}

// MinisTsStart starts the node. authKey may be empty (interactive login; the
// AuthURL then shows up in MinisTsStatus).
//
//export MinisTsStart
func MinisTsStart(authKey, hostname, stateDir *C.char) *C.char {
	return tsResult("", tsnet.Start(C.GoString(authKey), C.GoString(hostname), C.GoString(stateDir)))
}

// MinisTsSetAcceptRoutes accepts (1) or ignores (0) subnet routes that
// peers advertise. Tailscale defaults to accepting; the app sets its own
// setting (default off) after MinisTsStart.
//
//export MinisTsSetAcceptRoutes
func MinisTsSetAcceptRoutes(on C.int) *C.char {
	return tsResult("", tsnet.SetAcceptRoutes(on != 0))
}

// MinisTsStop stops the SOCKS listener and the node (the login is kept).
//
//export MinisTsStop
func MinisTsStop() *C.char {
	return tsResult("", tsnet.Stop())
}

// MinisTsLogout signs the node out and stops it.
//
//export MinisTsLogout
func MinisTsLogout() *C.char {
	return tsResult("", tsnet.Logout())
}

// MinisTsStatus returns the node status as JSON.
//
//export MinisTsStatus
func MinisTsStatus() *C.char {
	return tsResult(tsnet.StatusJSON(), nil)
}

// MinisTsRoutes returns the prefixes currently reachable through the tailnet
// and the MagicDNS suffix.
//
//export MinisTsRoutes
func MinisTsRoutes() *C.char {
	return tsResult(tsnet.RoutesJSON(), nil)
}

// MinisTsDialTest dials addr ("host:port") through the tailnet.
//
//export MinisTsDialTest
func MinisTsDialTest(addr *C.char, timeoutMs C.int) *C.char {
	d, err := tsnet.DialTest(C.GoString(addr), time.Duration(timeoutMs)*time.Millisecond)
	if err != nil {
		return tsResult("", err)
	}
	b, _ := json.Marshal(map[string]any{"ms": d.Milliseconds()})
	return tsResult(string(b), nil)
}

// MinisTsListenSocks starts a local SOCKS5 proxy on addr ("127.0.0.1:0" picks
// a port). The result carries the bound address and generated credentials.
//
//export MinisTsListenSocks
func MinisTsListenSocks(addr *C.char) *C.char {
	return tsResult(tsnet.ListenSocks(C.GoString(addr)))
}

// MinisTsFreeString frees a string returned by the functions above.
//
//export MinisTsFreeString
func MinisTsFreeString(s *C.char) {
	C.free(unsafe.Pointer(s))
}
