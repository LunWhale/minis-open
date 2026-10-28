package gomobile

// Android entry points for the embedded Tailscale node (../tsnet) and the
// local network entry (../nethub). They mirror the iOS cgo exports in
// ../librclone/{tsnet,nethub}_export.go one for one (MinisTsStart ->
// TsStart, MinisNetConfigure -> NetConfigure, ...), with the same JSON
// envelope: {"ok":true[,"result":...]} or {"ok":false,"error":"..."}, so
// both apps parse one format. gobind cannot pass function pointers, so the
// log callback is an interface the app implements (LogSink).
//
// Every call that touches the network blocks; callers stay off the main
// thread.

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"os"
	"runtime"
	"strconv"
	"sync"
	"time"

	"github.com/OpenMinis/minis-rclone/nethub"
	"github.com/OpenMinis/minis-rclone/tsnet"
)

// LogSink receives the node's and the entry's log lines.
type LogSink interface {
	Line(line string)
}

var (
	hubOnce sync.Once
	hub     *nethub.Hub
)

func theHub() *nethub.Hub {
	hubOnce.Do(func() { hub = nethub.New(tsnet.ProxyView{}, tsnet.Logf) })
	return hub
}

func envelope(extra string, err error) string {
	if err != nil {
		b, _ := json.Marshal(map[string]any{"ok": false, "error": err.Error()})
		return string(b)
	}
	if extra != "" {
		return `{"ok":true,"result":` + extra + `}`
	}
	return `{"ok":true}`
}

func marshal(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// TsSetLogger routes log lines to sink (nil turns logging off).
func TsSetLogger(sink LogSink) {
	if sink == nil {
		tsnet.SetLogger(nil)
		return
	}
	tsnet.SetLogger(sink.Line)
}

// TsSetDefaultRouteInterface passes the OS default interface ("wlan0",
// "rmnet_data0"; "" = no network) to the node's network monitor.
func TsSetDefaultRouteInterface(ifName string) {
	tsnet.SetDefaultRouteInterface(ifName)
}

// TsSetInterfaces replaces the interface list the node sees (JSON array of
// tsnet.AppInterface). Android cannot read it through netlink; see
// tsnet/netmon_app.go.
func TsSetInterfaces(interfacesJSON string) string {
	return envelope("", tsnet.SetInterfaces(interfacesJSON))
}

// TsNetworkChanged wakes the node's network monitor after an OS network change.
func TsNetworkChanged() {
	tsnet.NetworkChanged()
}

// TsStart starts the node. authKey may be empty (interactive login; the
// authURL then shows up in TsStatus).
//
// TS_LOGS_DIR: tailscale's logpolicy.LogsDir looks for a writable directory
// for its log state (log ID config; nothing is uploaded, see
// ts_omit_logtail). On Android none of its fallbacks exists - no
// os.UserCacheDir ($HOME/$XDG unset), the working directory is "/", and the
// default temp dir /data/local/tmp is not the app's - so it PANICS ("no safe
// place found to store log state") and takes the whole app process down.
// Point it at the node's own private state directory before every start.
func TsStart(authKey, hostname, stateDir string) string {
	if os.Getenv("TS_LOGS_DIR") == "" && stateDir != "" {
		os.Setenv("TS_LOGS_DIR", stateDir)
	}
	return envelope("", tsnet.Start(authKey, hostname, stateDir))
}

// TsSetAcceptRoutes accepts or ignores subnet routes that peers advertise.
func TsSetAcceptRoutes(on bool) string {
	return envelope("", tsnet.SetAcceptRoutes(on))
}

// TsSetExitNode uses the peer with Tailscale IP ip as exit node ("" = none).
func TsSetExitNode(ip string) string {
	return envelope("", tsnet.SetExitNode(ip))
}

// TsStop stops the node (the login is kept).
func TsStop() string {
	return envelope("", tsnet.Stop())
}

// TsLogout signs the node out and stops it.
func TsLogout() string {
	return envelope("", tsnet.Logout())
}

// TsStatus returns the node status.
func TsStatus() string {
	return envelope(tsnet.StatusJSON(), nil)
}

// TsRoutes returns the prefixes reachable through the tailnet and the
// MagicDNS suffix.
func TsRoutes() string {
	return envelope(tsnet.RoutesJSON(), nil)
}

// TsDialTest dials addr ("host:port") through the tailnet: {"ms":N}.
func TsDialTest(addr string, timeoutMs int) string {
	d, err := tsnet.DialTest(addr, time.Duration(timeoutMs)*time.Millisecond)
	if err != nil {
		return envelope("", err)
	}
	return envelope(marshal(map[string]any{"ms": d.Milliseconds()}), nil)
}

// NetConfigure applies the routing configuration (nethub.Config JSON, proxy
// passwords included; never log it) and starts the entry if needed:
// {"addr","port","password","httpPort"}. httpPort is the entry's HTTP proxy
// front (nethub/httpentry.go) for OkHttp and WebView; 0 if it could not
// listen, and those clients then go direct.
func NetConfigure(configJSON string) string {
	var cfg nethub.Config
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		return envelope("", err)
	}
	h := theHub()
	h.Configure(cfg)
	addr, pass, err := h.Start(0)
	if err != nil {
		return envelope("", err)
	}
	_, portS, _ := net.SplitHostPort(addr)
	port, _ := strconv.Atoi(portS)
	httpPort := 0
	if haddr, err := h.StartHTTP(0); err == nil {
		_, hp, _ := net.SplitHostPort(haddr)
		httpPort, _ = strconv.Atoi(hp)
	} else {
		tsnet.Logf("[Net][Entry] http front failed: %v (OkHttp and WebView clients go direct)", err)
	}
	return envelope(marshal(map[string]any{"addr": addr, "port": port, "password": pass, "httpPort": httpPort}), nil)
}

// NetStop stops the local entry (clients fall back to direct).
func NetStop() string {
	theHub().StopHTTP()
	theHub().Stop()
	return envelope("", nil)
}

// NetStatus: {"listening","addr","httpAddr","connections","failures"}.
func NetStatus() string {
	h := theHub()
	conns, fails := h.Stats()
	addr := h.Addr()
	return envelope(marshal(map[string]any{"listening": addr != "", "addr": addr, "httpAddr": h.HTTPAddr(),
		"connections": conns, "failures": fails}), nil)
}

// NetHookRoutes reports which destinations of tag the transparent
// forwarding (proot's xnet extension) must hand to the app: nethub.HookSnapshot
// as JSON, {"route","tailnet","everything","hook","exempt","self"}, exactly as
// iOS's MinisNetHookRoutes. localJSON is the device's current networks as a
// JSON array of CIDRs; entries that do not parse are skipped.
func NetHookRoutes(tag, localJSON string) string {
	var raw []string
	if localJSON != "" {
		if err := json.Unmarshal([]byte(localJSON), &raw); err != nil {
			return envelope("", err)
		}
	}
	var local []netip.Prefix
	for _, r := range raw {
		if p, err := netip.ParsePrefix(r); err == nil {
			local = append(local, p)
		}
	}
	return envelope(marshal(theHub().HookRoutes(tag, local)), nil)
}

// NetHookRoutes2 is NetHookRoutes plus the stage 2 fields ("udpHook",
// "resolvers", "dnsIntercept"), as iOS's MinisNetHookRoutes2
// [FEAT-261021-23]. resolversJSON is the shell's nameservers (its
// /etc/resolv.conf) as a JSON array; entries that do not parse are skipped.
func NetHookRoutes2(tag, localJSON, resolversJSON string) string {
	var rawLocal, rawResolvers []string
	if localJSON != "" {
		if err := json.Unmarshal([]byte(localJSON), &rawLocal); err != nil {
			return envelope("", err)
		}
	}
	if resolversJSON != "" {
		if err := json.Unmarshal([]byte(resolversJSON), &rawResolvers); err != nil {
			return envelope("", err)
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
	return envelope(marshal(theHub().HookRoutesWithResolvers(tag, local, resolvers)), nil)
}

// NetShellProbe checks the shell's UDP and DNS paths from inside the app, as
// iOS's MinisNetShellProbe: a UDP round trip through the entry's relay, and
// each name of namesJSON looked up as the shell's intercepted DNS is
// answered, with resolver ("ip" or "ip:port"). Result:
// {"udp":{"ms","error"},"dns":[{name,via,rule,rcode,answers,ms,error}]}.
func NetShellProbe(resolver, namesJSON string, timeoutMs int) string {
	timeout := time.Duration(timeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	var names []string
	if namesJSON != "" {
		if err := json.Unmarshal([]byte(namesJSON), &names); err != nil {
			return envelope("", err)
		}
	}
	h := theHub()
	udp := map[string]any{}
	if d, err := h.UDPSelfTest(timeout); err != nil {
		udp["error"] = fmt.Sprintf("stage=%s class=%s: %v", nethub.Stage(err), nethub.Classify(err), err)
	} else {
		udp["ms"] = d.Milliseconds()
	}
	if _, _, err := net.SplitHostPort(resolver); err != nil && resolver != "" {
		resolver = net.JoinHostPort(resolver, "53")
	}
	var dns []nethub.DNSProbeResult
	if resolver != "" {
		dns = h.DNSProbe(resolver, names)
	}
	return envelope(marshal(map[string]any{"udp": udp, "dns": dns}), nil)
}

var (
	xmapMu sync.Mutex
	xmap   *nethub.XMap
)

// NetXparentStart starts (or keeps) the listener behind proot's xnet
// extension, routing what it receives as tag; dir is the owner-only
// directory proot writes destinations to. {"port4","port6","udpPort"}
// (port6 0 when ::1 is unavailable; udpPort is connected UDP sockets'
// listener, FEAT-261021-23).
func NetXparentStart(dir, tag string) string {
	xmapMu.Lock()
	defer xmapMu.Unlock()
	if xmap == nil {
		xmap = nethub.NewXMap(theHub(), dir, tag)
	}
	p4, p6, err := xmap.Start()
	if err != nil {
		return envelope("", err)
	}
	return envelope(marshal(map[string]any{"port4": p4, "port6": p6, "udpPort": xmap.UDPPort()}), nil)
}

// NetXparentStop stops that listener; relayed connections finish on their own.
func NetXparentStop() string {
	xmapMu.Lock()
	defer xmapMu.Unlock()
	if xmap != nil {
		xmap.Stop()
	}
	return envelope("", nil)
}

// NetXparentStatus: {"port4","port6","udpPort","connections","failures",
// "udp":{XMapUDPStats},"relay":{the entry's UDPStats}}.
func NetXparentStatus() string {
	xmapMu.Lock()
	defer xmapMu.Unlock()
	relay := theHub().UDPStats()
	if xmap == nil {
		return envelope(marshal(map[string]any{"port4": 0, "port6": 0, "udpPort": 0, "connections": 0, "failures": 0,
			"udp": nethub.XMapUDPStats{}, "relay": relay}), nil)
	}
	p4, p6 := xmap.Ports()
	c, f := xmap.Stats()
	return envelope(marshal(map[string]any{"port4": p4, "port6": p6, "udpPort": xmap.UDPPort(), "connections": c,
		"failures": f, "udp": xmap.UDPStats(), "relay": relay}), nil)
}

// NetDecide reports where a connection from tag to host would go.
func NetDecide(tag, host string) string {
	d := theHub().Decide(tag, host)
	return envelope(marshal(map[string]any{"kind": d.Kind, "route": d.Route, "rule": d.Rule, "exit": d.Exit()}), nil)
}

// NetProbe dials addr for tag as an entry client would be routed, closes
// it, and reports the decision and the time taken.
func NetProbe(tag, addr string, timeoutMs int) string {
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	t0 := time.Now()
	c, d, err := theHub().DialVia(ctx, tag, addr)
	if err != nil {
		return marshal(map[string]any{"ok": false, "error": err.Error(), "kind": d.Kind, "route": d.Route})
	}
	c.Close()
	return envelope(marshal(map[string]any{"kind": d.Kind, "route": d.Route, "ms": time.Since(t0).Milliseconds()}), nil)
}

// NetTestUpstream connects through one upstream (nethub.Upstream JSON) to
// target ("host:port"): {"ms":N}.
func NetTestUpstream(upstreamJSON, target string, timeoutMs int) string {
	var u nethub.Upstream
	if err := json.Unmarshal([]byte(upstreamJSON), &u); err != nil {
		return envelope("", err)
	}
	d, err := nethub.TestUpstream(u, target, time.Duration(timeoutMs)*time.Millisecond)
	if err != nil {
		return envelope("", err)
	}
	return envelope(marshal(map[string]any{"ms": d.Milliseconds()}), nil)
}

// NetHealth: liveness of the local entry plus Go runtime numbers (iOS
// MinisNetHealth): {"alive","addr","httpAddr","active","connections",
// "failures","goroutines","heapMB"}.
func NetHealth() string {
	h := theHub()
	conns, fails := h.Stats()
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	return envelope(marshal(map[string]any{"alive": h.Alive(), "addr": h.Addr(), "httpAddr": h.HTTPAddr(),
		"active": h.Active(), "connections": conns, "failures": fails, "goroutines": runtime.NumGoroutine(),
		"heapMB": float64(ms.HeapAlloc) / (1 << 20)}), nil)
}

// NetSelfTest connects to the entry as a client would (auth + relay to a
// local echo): {"ms":N}, or the failing stage and class.
func NetSelfTest(timeoutMs int) string {
	d, err := theHub().SelfTest(time.Duration(timeoutMs) * time.Millisecond)
	if err != nil {
		return envelope("", fmt.Errorf("stage=%s class=%s: %w", nethub.Stage(err), nethub.Classify(err), err))
	}
	return envelope(marshal(map[string]any{"ms": d.Milliseconds()}), nil)
}

// NetDiagnose runs the same checks, in the same order and JSON, as iOS
// MinisNetDiagnose: entry self-test, each upstream, DNS, direct, then the
// Tailscale node. {"checks":[{name,status,detail,ms}],"runtime":{...}}.
// Secrets never appear in it.
func NetDiagnose(timeoutMs int) string {
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
		checks = append(checks, tsnet.Check{Name: "entry", Status: "skip", Detail: "local entry not running (nothing routed; everything direct)"})
	} else {
		d, err := h.SelfTest(timeout)
		add("entry", d, err, "listening on "+h.Addr()+", auth + relay ok")
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
	return envelope(marshal(map[string]any{"checks": checks, "runtime": map[string]any{
		"goroutines": runtime.NumGoroutine(), "heapMB": float64(ms.HeapAlloc) / (1 << 20),
		"activeConnections": h.Active(), "connections": conns, "failures": fails}}), nil)
}
