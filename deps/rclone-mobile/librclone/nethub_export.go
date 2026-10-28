package main

// C entry points for the local network entry (deps/rclone-mobile/nethub):
// a SOCKS5 server on 127.0.0.1 that routes each connection to the tailnet,
// an upstream proxy, or direct, by the caller's policy tag. Strings returned
// are freed with MinisTsFreeString, envelope {"ok":...} as for MinisTs*.

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"runtime"
	"strconv"
	"sync"
	"time"

	"github.com/OpenMinis/minis-rclone/nethub"
	"github.com/OpenMinis/minis-rclone/tsnet"
)

var (
	hubOnce sync.Once
	hub     *nethub.Hub
)

func theHub() *nethub.Hub {
	hubOnce.Do(func() { hub = nethub.New(tsnet.ProxyView{}, tsnet.Logf) })
	return hub
}

// MinisNetConfigure applies the routing configuration (nethub.Config as
// JSON, upstream passwords included) and starts the entry if it is not
// listening yet. Result: {"addr","port","password","httpPort"}. The password
// changes only when the process restarts. httpPort is the entry's HTTP proxy
// front (nethub/httpentry.go, same password and routing) for the iSH shell's
// HTTP(S)_PROXY: BusyBox wget, apk and Python cannot use socks5h. 0 when it
// could not listen; the shell then gets no HTTP proxy variables.
//
//export MinisNetConfigure
func MinisNetConfigure(configJSON *C.char) *C.char {
	var cfg nethub.Config
	if err := json.Unmarshal([]byte(C.GoString(configJSON)), &cfg); err != nil {
		return tsResult("", err)
	}
	h := theHub()
	h.Configure(cfg)
	addr, pass, err := h.Start(0)
	if err != nil {
		return tsResult("", err)
	}
	_, portS, _ := net.SplitHostPort(addr)
	port, _ := strconv.Atoi(portS)
	httpPort := 0
	if haddr, err := h.StartHTTP(0); err == nil {
		_, hp, _ := net.SplitHostPort(haddr)
		httpPort, _ = strconv.Atoi(hp)
	} else {
		tsnet.Logf("[Net][Entry] http front failed: %v (the shell gets no HTTP proxy variables)", err)
	}
	b, _ := json.Marshal(map[string]any{"addr": addr, "port": port, "password": pass, "httpPort": httpPort})
	return tsResult(string(b), nil)
}

// MinisNetStop stops the local entry (clients must fall back to direct).
//
//export MinisNetStop
func MinisNetStop() *C.char {
	theHub().StopHTTP()
	theHub().Stop()
	return tsResult("", nil)
}

// MinisNetStopHTTP stops only the HTTP front, behind the app's back: the
// debug fault injection for "iOS reclaimed the front's socket".
//
//export MinisNetStopHTTP
func MinisNetStopHTTP() *C.char {
	theHub().StopHTTP()
	return tsResult("", nil)
}

// MinisNetStatus: {"listening","addr","httpAddr","connections","failures"}.
//
//export MinisNetStatus
func MinisNetStatus() *C.char {
	h := theHub()
	conns, fails := h.Stats()
	addr := h.Addr()
	b, _ := json.Marshal(map[string]any{"listening": addr != "", "addr": addr, "httpAddr": h.HTTPAddr(),
		"connections": conns, "failures": fails, "udp": h.UDPStats()})
	return tsResult(string(b), nil)
}

// MinisNetHealth: liveness of the local entry plus Go runtime numbers, for
// the app's periodic health check and the diagnose screen:
// {"alive","addr","httpAddr","active","connections","failures","goroutines","heapMB"}.
// httpAddr is "" when the HTTP front is not listening.
//
//export MinisNetHealth
func MinisNetHealth() *C.char {
	h := theHub()
	conns, fails := h.Stats()
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	b, _ := json.Marshal(map[string]any{"alive": h.Alive(), "addr": h.Addr(), "httpAddr": h.HTTPAddr(), "active": h.Active(),
		"connections": conns, "failures": fails, "goroutines": runtime.NumGoroutine(),
		"heapMB": float64(ms.HeapAlloc) / (1 << 20), "udp": h.UDPStats()})
	return tsResult(string(b), nil)
}

// MinisNetDiagnose runs every check of the diagnose screen in order: local
// entry self-test, each upstream proxy (with its credentials), system DNS,
// a direct connection, then the Tailscale node (state, MagicDNS, ping).
// Result: {"checks":[{name,status,detail,ms}], "runtime":{...}}. Secrets
// never appear in it.
//
//export MinisNetDiagnose
func MinisNetDiagnose(timeoutMs C.int) *C.char {
	timeout := time.Duration(timeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 8 * time.Second
	}
	h := theHub()
	checks := []tsnet.Check{}
	add := func(name string, d time.Duration, err error, okDetail string) {
		c := tsnet.Check{Name: name, Ms: d.Milliseconds()}
		if err != nil {
			c.Status = "fail"
			c.Detail = fmt.Sprintf("stage=%s class=%s: %v", nethub.Stage(err), nethub.Classify(err), err)
		} else {
			c.Status, c.Detail = "pass", okDetail
		}
		checks = append(checks, c)
	}
	if h.Addr() == "" {
		checks = append(checks, tsnet.Check{Name: "entry", Status: "skip", Detail: "local entry is not listening"})
	} else {
		d, err := h.SelfTest(timeout)
		add("entry", d, err, "listening on "+h.Addr()+", auth + relay ok")
		if h.HTTPAddr() == "" {
			checks = append(checks, tsnet.Check{Name: "http entry", Status: "fail",
				Detail: "http front is not listening (the shell's wget / apk / pip cannot use the route)"})
		} else {
			d, err := h.HTTPSelfTest(timeout)
			add("http entry", d, err, "listening on "+h.HTTPAddr()+", auth + CONNECT relay ok")
		}
	}
	for _, u := range h.Upstreams() {
		name := u.Name
		if name == "" {
			name = u.ID
		}
		d, err := nethub.TestUpstream(u, "www.apple.com:443", timeout)
		add("proxy "+name, d, err, fmt.Sprintf("%s %s:%d -> www.apple.com:443 ok", u.Type, u.Host, u.Port))
	}
	d, addrs, err := nethub.ResolveProbe("www.apple.com", timeout)
	add("dns", d, err, fmt.Sprintf("www.apple.com -> %d address(es)", len(addrs)))
	d, err = nethub.DirectProbe("www.apple.com:443", timeout)
	add("direct", d, err, "www.apple.com:443 reachable without any route")
	checks = append(checks, tsnet.Diagnose(timeout)...)
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	conns, fails := h.Stats()
	b, _ := json.Marshal(map[string]any{"checks": checks, "runtime": map[string]any{
		"goroutines": runtime.NumGoroutine(), "heapMB": float64(ms.HeapAlloc) / (1 << 20),
		"activeConnections": h.Active(), "connections": conns, "failures": fails}})
	return tsResult(string(b), nil)
}

// MinisNetDecide reports where a connection from tag to host would go.
//
//export MinisNetDecide
func MinisNetDecide(tag, host *C.char) *C.char {
	d := theHub().Decide(C.GoString(tag), C.GoString(host))
	b, _ := json.Marshal(map[string]any{"kind": d.Kind, "route": d.Route, "rule": d.Rule, "exit": d.Exit()})
	return tsResult(string(b), nil)
}

// MinisNetHookRoutes reports which destinations of tag iSH's transparent
// forwarding (deps/ish fs/xnet.h) must hand to the entry: nethub.HookSnapshot
// as JSON, {"route","tailnet","everything","hook","exempt","self"}.
// localJSON is the device's current networks as a JSON array of CIDRs
// (e.g. ["10.17.41.0/24"]); entries that do not parse are skipped.
//
//export MinisNetHookRoutes
func MinisNetHookRoutes(tag, localJSON *C.char) *C.char {
	var raw []string
	if s := C.GoString(localJSON); s != "" {
		if err := json.Unmarshal([]byte(s), &raw); err != nil {
			return tsResult("", err)
		}
	}
	var local []netip.Prefix
	for _, r := range raw {
		if p, err := netip.ParsePrefix(r); err == nil {
			local = append(local, p)
		}
	}
	b, _ := json.Marshal(theHub().HookRoutes(C.GoString(tag), local))
	return tsResult(string(b), nil)
}

// MinisNetHookRoutes2 is MinisNetHookRoutes plus iSH's stage 2 fields
// ("udpHook", "resolvers", "dnsIntercept"; ish_xnet_set_routes2).
// resolversJSON is the shell's nameservers as a JSON array of addresses
// (its /etc/resolv.conf); entries that do not parse are skipped.
//
//export MinisNetHookRoutes2
func MinisNetHookRoutes2(tag, localJSON, resolversJSON *C.char) *C.char {
	var rawLocal, rawResolvers []string
	if s := C.GoString(localJSON); s != "" {
		if err := json.Unmarshal([]byte(s), &rawLocal); err != nil {
			return tsResult("", err)
		}
	}
	if s := C.GoString(resolversJSON); s != "" {
		if err := json.Unmarshal([]byte(s), &rawResolvers); err != nil {
			return tsResult("", err)
		}
	}
	var local []netip.Prefix
	for _, r := range rawLocal {
		if p, err := netip.ParsePrefix(r); err == nil {
			local = append(local, p)
		}
	}
	var resolvers []netip.Addr
	for _, r := range rawResolvers {
		if a, err := netip.ParseAddr(r); err == nil {
			resolvers = append(resolvers, a)
		}
	}
	b, _ := json.Marshal(theHub().HookRoutesWithResolvers(C.GoString(tag), local, resolvers))
	return tsResult(string(b), nil)
}

// MinisNetShellProbe checks the iSH shell's UDP and DNS paths from inside
// the app (nethub/shellprobe.go): a UDP round trip through the entry's
// relay, and each name of namesJSON looked up as the shell's intercepted DNS
// is answered, with resolver ("ip" or "ip:port", the shell's nameserver).
// Result: {"udp":{"ms","error"},"dns":[{name,via,rule,rcode,answers,ms,error}]}.
//
//export MinisNetShellProbe
func MinisNetShellProbe(resolver, namesJSON *C.char, timeoutMs C.int) *C.char {
	timeout := time.Duration(timeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	var names []string
	if s := C.GoString(namesJSON); s != "" {
		if err := json.Unmarshal([]byte(s), &names); err != nil {
			return tsResult("", err)
		}
	}
	h := theHub()
	udp := map[string]any{}
	if d, err := h.UDPSelfTest(timeout); err != nil {
		udp["error"] = fmt.Sprintf("stage=%s class=%s: %v", nethub.Stage(err), nethub.Classify(err), err)
	} else {
		udp["ms"] = d.Milliseconds()
	}
	r := C.GoString(resolver)
	if _, _, err := net.SplitHostPort(r); err != nil && r != "" {
		r = net.JoinHostPort(r, "53")
	}
	var dns []nethub.DNSProbeResult
	if r != "" {
		dns = h.DNSProbe(r, names)
	}
	b, _ := json.Marshal(map[string]any{"udp": udp, "dns": dns})
	return tsResult(string(b), nil)
}

// MinisNetProbe dials addr for tag exactly as a SOCKS client of the entry
// would be routed, closes it, and reports the decision and time taken.
//
//export MinisNetProbe
func MinisNetProbe(tag, addr *C.char, timeoutMs C.int) *C.char {
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	t0 := time.Now()
	c, d, err := theHub().DialVia(ctx, C.GoString(tag), C.GoString(addr))
	if err != nil {
		b, _ := json.Marshal(map[string]any{"ok": false, "error": err.Error(), "kind": d.Kind, "route": d.Route})
		return C.CString(string(b))
	}
	c.Close()
	b, _ := json.Marshal(map[string]any{"kind": d.Kind, "route": d.Route, "ms": time.Since(t0).Milliseconds()})
	return tsResult(string(b), nil)
}

// MinisNetTestUpstream connects through one upstream (nethub.Upstream JSON)
// to target ("host:port") and reports the time taken.
//
//export MinisNetTestUpstream
func MinisNetTestUpstream(upstreamJSON, target *C.char, timeoutMs C.int) *C.char {
	var u nethub.Upstream
	if err := json.Unmarshal([]byte(C.GoString(upstreamJSON)), &u); err != nil {
		return tsResult("", err)
	}
	d, err := nethub.TestUpstream(u, C.GoString(target), time.Duration(timeoutMs)*time.Millisecond)
	if err != nil {
		return tsResult("", err)
	}
	b, _ := json.Marshal(map[string]any{"ms": d.Milliseconds()})
	return tsResult(string(b), nil)
}

// MinisTsSetExitNode uses the peer with Tailscale IP ip as exit node ("" = none).
//
//export MinisTsSetExitNode
func MinisTsSetExitNode(ip *C.char) *C.char {
	return tsResult("", tsnet.SetExitNode(C.GoString(ip)))
}
