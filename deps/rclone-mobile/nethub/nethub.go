// Package nethub is the app's local network entry: a SOCKS5 server on
// 127.0.0.1 that every in-app client (URLSession, WKWebView, the iSH shell)
// can be pointed at, and that sends each connection to the tailnet, an
// upstream proxy, or out directly, by policy.
//
// Authentication: the password is a per-process random secret, so other
// apps on the device cannot use the entry. The username carries the policy
// TAG of the caller ("default", "shell", "browser", "mcp", "backup",
// "prov:<id>"); the configuration maps tags to routes.
//
// Routes:
//
//	direct       no proxy and no exit node: out directly, except tailnet
//	             destinations, which go through the tailnet while it is on
//	tailscale    like direct, but while an exit node is in use everything
//	             else goes through the tailnet (the exit node) too
//	proxy:<id>   tailnet destinations through the tailnet (Tailscale and a
//	             proxy stack); everything else through upstream <id>, unless
//	             the host matches that upstream's bypass list (then direct)
//	default      the configured default route
//
// A tailnet destination is an IP inside the node's routing table (exit-node
// 0/0 excluded) or a MagicDNS name. The table is dynamic (subnet routes,
// peers), never a hard-coded 100.64.0.0/10.
package nethub

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Upstream is a user-configured proxy.
type Upstream struct {
	ID       string   `json:"id"`
	Name     string   `json:"name,omitempty"` // display name, for logs
	Type     string   `json:"type"`           // socks5 | http | https
	Host     string   `json:"host"`
	Port     int      `json:"port"`
	Username string   `json:"username,omitempty"`
	Password string   `json:"password,omitempty"`
	Bypass   []string `json:"bypass,omitempty"` // host, *.suffix / .suffix, CIDR, IP
}

// Config is pushed from the app whenever a setting changes.
type Config struct {
	DefaultRoute string            `json:"defaultRoute"` // direct | tailscale | proxy:<id>
	Tags         map[string]string `json:"tags"`         // tag -> route ("default" = DefaultRoute)
	Upstreams    []Upstream        `json:"upstreams"`
	Tailscale    bool              `json:"tailscale"` // node enabled in settings
	// ExitNodeDNS: while an exit node is in use, the iSH shell's DNS queries
	// for non-tailnet names are answered through the exit node too (dns.go).
	// Off by default: they go to the shell's own resolver, as without the
	// hub, which tells that resolver's network what is looked up.
	ExitNodeDNS bool `json:"exitNodeDNS,omitempty"`
}

// Tailnet is what the hub needs from the Tailscale node; satisfied by
// package tsnet through an adapter in the exports, faked in tests.
type Tailnet interface {
	Running() bool
	Dial(ctx context.Context, network, addr string) (net.Conn, error)
	// Prefixes reachable through the tailnet, exit-node 0/0 excluded.
	Prefixes() []netip.Prefix
	ExitNodeActive() bool
	// IsTailnetName reports MagicDNS names (full or a peer's short name).
	IsTailnetName(host string) bool
}

// PeerDescriber is optionally implemented by a Tailnet: a short description
// of the peer behind a tailnet address (name, online, direct/relay path),
// for dial logs. Must not block.
type PeerDescriber interface {
	DescribePeer(host string) string
}

// ExitIPv6Reporter is optionally implemented by a Tailnet: whether the exit
// node in use routes IPv6 (::/0). Must not block.
type ExitIPv6Reporter interface {
	ExitNodeIPv6() bool
}

// ExitOnlineReporter is optionally implemented by a Tailnet: whether the
// exit node in use is online. Must not block.
type ExitOnlineReporter interface {
	ExitNodeOnline() bool
}

// errExitOffline: the exit node is offline, and the node would otherwise
// send the connection out through the system network - a silent direct
// connection the user's route never asked for (FIX-261025-27). Classified
// "unreachable" by its text.
var errExitOffline = errors.New("the exit node is offline (host is down)")

// exitOffline: d leaves through an exit node that is offline right now.
func (h *Hub) exitOffline(d Decision) bool {
	if d.Rule != "exit-node" {
		return false
	}
	r, ok := h.ts.(ExitOnlineReporter)
	return ok && !r.ExitNodeOnline()
}

// Decision is where one connection goes.
type Decision struct {
	Kind     string // direct | tailscale | proxy
	Upstream *Upstream
	Route    string // the route that applied, for logs
	// Rule that decided: tailnet | route | bypass | exit-node | missing-proxy
	Rule string
}

// Exit names the outbound path for logs: direct, tailscale, proxy:<name>.
func (d Decision) Exit() string {
	if d.Kind == "proxy" && d.Upstream != nil {
		n := d.Upstream.Name
		if n == "" {
			n = d.Upstream.ID
		}
		return "proxy:" + n
	}
	return d.Kind
}

type Hub struct {
	mu       sync.RWMutex
	cfg      Config
	ts       Tailnet
	ln       net.Listener
	password string
	logf     func(string, ...any)
	dialer   net.Dialer
	// dialDirect is the direct path; tests replace it to map fake hosts.
	dialDirect func(ctx context.Context, network, addr string) (net.Conn, error)

	// counters for status
	conns, failures atomic.Int64
	active          atomic.Int64 // connections being relayed now
	// dead is set when the listener stopped without Stop (e.g. iOS reclaimed
	// the socket while suspended); Alive() reports it so the app restarts it.
	dead atomic.Bool

	policyLog, okLog, failLog, entryLog *limiter

	// exits: consecutive failures per proxy / Tailscale (exitalert.go).
	exits *exitTracker

	// exitV6Dead: when an IPv6 dial through the exit node last failed as
	// unreachable (unix nanos, 0 = never); see exitIPv6Usable.
	exitV6Dead atomic.Int64
	// exitV6Probed: when exitIPv6Usable last probed IPv6 through the exit
	// node (unix nanos, 0 = never).
	exitV6Probed atomic.Int64

	// UDP associations (udp.go).
	udp      udpCounters
	udpLimit udpLimits // zero = defaults; guarded by mu
	assocMu  sync.Mutex
	assocs   map[*udpAssoc]struct{}
}

func New(ts Tailnet, logf func(string, ...any)) *Hub {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	h := &Hub{ts: ts, logf: logf, dialer: net.Dialer{Timeout: connectDeadline, KeepAlive: 30 * time.Second},
		policyLog: newLimiter(60 * time.Second), okLog: newLimiter(60 * time.Second),
		failLog: newLimiter(10 * time.Second), entryLog: newLimiter(10 * time.Second),
		exits: newExitTracker()}
	h.dialDirect = h.dialer.DialContext
	return h
}

func (h *Hub) Configure(c Config) {
	if c.Tags == nil {
		c.Tags = map[string]string{}
	}
	if c.DefaultRoute == "" {
		c.DefaultRoute = "direct"
	}
	h.mu.Lock()
	changed := !reflect.DeepEqual(h.cfg, c)
	h.cfg = c
	h.mu.Unlock()
	// A streak was against the old settings (e.g. a proxy the user just
	// fixed). The app re-sends an unchanged config often; that keeps them.
	if changed {
		h.resetExits()
	}
}

// Start listens on 127.0.0.1 (port 0 = any). Idempotent: a running hub keeps
// its port and password.
func (h *Hub) Start(port int) (addr string, password string, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.ln != nil {
		return h.ln.Addr().String(), h.password, nil
	}
	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return "", "", err
	}
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		ln.Close()
		return "", "", err
	}
	h.ln, h.password = ln, hex.EncodeToString(b)
	h.dead.Store(false)
	go h.serve(ln)
	h.logf("[Net][Entry] listening on %s", ln.Addr())
	return ln.Addr().String(), h.password, nil
}

// Alive reports whether the entry is listening and its listener has not died.
func (h *Hub) Alive() bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.ln != nil && !h.dead.Load()
}

// listenerDied is called by the accept loop when Accept fails on a listener
// that was not closed by Stop: forget it so the next Start opens a new one.
func (h *Hub) listenerDied(ln net.Listener, err error) {
	h.mu.Lock()
	if h.ln == ln {
		h.ln = nil
		h.dead.Store(true)
		h.mu.Unlock()
		h.logf("[Net][Entry] listener %s died: %v (clients fall back to direct until it is restarted)", ln.Addr(), err)
		return
	}
	h.mu.Unlock()
}

func (h *Hub) Stop() {
	h.mu.Lock()
	ln := h.ln
	h.ln = nil
	h.mu.Unlock()
	if ln != nil {
		ln.Close()
		h.logf("[Net][Entry] stopped (was %s)", ln.Addr())
	}
}

func (h *Hub) Addr() string {
	h.mu.RLock()
	defer h.mu.RUnlock()
	if h.ln == nil {
		return ""
	}
	return h.ln.Addr().String()
}

func (h *Hub) Stats() (conns, failures int64) { return h.conns.Load(), h.failures.Load() }

// Active is the number of connections being relayed right now.
func (h *Hub) Active() int64 { return h.active.Load() }

// MARK: - Policy

// routeFor resolves a tag to a concrete route (never "default").
func (h *Hub) routeFor(tag string) string {
	h.mu.RLock()
	defer h.mu.RUnlock()
	r := h.cfg.Tags[tag]
	if r == "" || r == "default" {
		r = h.cfg.DefaultRoute
	}
	if r == "" || r == "default" {
		r = "direct"
	}
	return r
}

// Upstreams returns a copy of the configured upstream proxies.
func (h *Hub) Upstreams() []Upstream {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return append([]Upstream(nil), h.cfg.Upstreams...)
}

func (h *Hub) upstream(id string) *Upstream {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for i := range h.cfg.Upstreams {
		if h.cfg.Upstreams[i].ID == id {
			u := h.cfg.Upstreams[i]
			return &u
		}
	}
	return nil
}

func (h *Hub) tailscaleUp() bool {
	h.mu.RLock()
	on := h.cfg.Tailscale
	h.mu.RUnlock()
	return on && h.ts != nil && h.ts.Running()
}

// isTailnetDest: an IP inside the routing table, or a MagicDNS name.
func (h *Hub) isTailnetDest(host string) bool {
	if ip, err := netip.ParseAddr(strings.Trim(host, "[]")); err == nil {
		ip = ip.Unmap()
		for _, p := range h.ts.Prefixes() {
			if p.Bits() > 0 && p.Contains(ip) {
				return true
			}
		}
		return false
	}
	return h.ts.IsTailnetName(host)
}

// Decide picks where a connection from `tag` to `host` goes.
func (h *Hub) Decide(tag, host string) Decision {
	route := h.routeFor(tag)
	// Tailnet destinations always go through the tailnet while it is on,
	// whatever the route: a route chooses how the REST of the traffic leaves.
	tsUp := h.tailscaleUp()
	if tsUp && h.isTailnetDest(host) {
		return Decision{Kind: "tailscale", Route: route, Rule: "tailnet"}
	}
	switch {
	case route == "direct":
		return Decision{Kind: "direct", Route: route, Rule: "route"}
	case route == "tailscale":
		if isLoopbackHost(host) {
			// This device, never the exit node (the diagnostics' own
			// self-tests and a shell's localhost services dial it).
			return Decision{Kind: "direct", Route: route, Rule: "loopback"}
		}
		if tsUp && h.ts.ExitNodeActive() {
			return Decision{Kind: "tailscale", Route: route, Rule: "exit-node"}
		}
		return Decision{Kind: "direct", Route: route, Rule: "route"}
	case strings.HasPrefix(route, "proxy:"):
		u := h.upstream(strings.TrimPrefix(route, "proxy:"))
		if u == nil {
			// A deleted proxy must not take traffic down with it.
			return Decision{Kind: "direct", Route: route + "(missing)", Rule: "missing-proxy"}
		}
		if MatchBypass(u.Bypass, host) {
			return Decision{Kind: "direct", Route: route + "(bypass)", Rule: "bypass"}
		}
		return Decision{Kind: "proxy", Upstream: u, Route: route, Rule: "route"}
	}
	return Decision{Kind: "direct", Route: route, Rule: "route"}
}

// isLoopbackHost: localhost, *.localhost, 127.0.0.0/8 or ::1.
func isLoopbackHost(host string) bool {
	h := strings.ToLower(strings.Trim(host, "[]"))
	if h == "localhost" || strings.HasSuffix(h, ".localhost") {
		return true
	}
	ip, err := netip.ParseAddr(h)
	return err == nil && ip.Unmap().IsLoopback()
}

// MatchBypass: exact host, "*.suffix" / ".suffix", CIDR, or IP. localhost and
// loopback always bypass.
func MatchBypass(list []string, host string) bool {
	if isLoopbackHost(host) {
		return true
	}
	h := strings.ToLower(strings.Trim(host, "[]"))
	ip, ipErr := netip.ParseAddr(h)
	for _, raw := range list {
		e := strings.ToLower(strings.TrimSpace(raw))
		if e == "" {
			continue
		}
		if strings.Contains(e, "/") {
			if p, err := netip.ParsePrefix(e); err == nil && ipErr == nil && p.Contains(ip.Unmap()) {
				return true
			}
			continue
		}
		if strings.HasPrefix(e, "*.") || strings.HasPrefix(e, ".") {
			suf := strings.TrimPrefix(strings.TrimPrefix(e, "*"), ".")
			if h == suf || strings.HasSuffix(h, "."+suf) {
				return true
			}
			continue
		}
		if h == e {
			return true
		}
	}
	return false
}

// MARK: - Dialing

func (h *Hub) dial(ctx context.Context, d Decision, addr string) (net.Conn, error) {
	switch d.Kind {
	case "tailscale":
		if h.exitOffline(d) {
			return nil, stageErr("tailnet", errExitOffline)
		}
		c, err := h.dialTailnet(ctx, addr)
		h.noteExitIPv6(d, addr, err)
		return c, stageErr("tailnet", err)
	case "proxy":
		return DialUpstream(ctx, &h.dialer, *d.Upstream, addr)
	default:
		c, err := h.dialDirect(ctx, "tcp", addr)
		return c, stageErr("direct", err)
	}
}

// dialTailnet dials addr through the node. The node resolves a host name
// itself and dials only the first address it gets back, with no fallback:
// an AAAA answer first on a path without IPv6 (an exit node, a tailnet that
// has none) failed every such dial with "network is unreachable" although
// IPv4 worked (FIX-261025-27). A host name is therefore dialed as tcp4 first
// and as tcp6 only when that fails; an IP literal or a tailnet name (answered
// from the node's own map in either family) is dialed as given.
func (h *Hub) dialTailnet(ctx context.Context, addr string) (net.Conn, error) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}
	if _, ipErr := netip.ParseAddr(host); ipErr == nil || h.ts.IsTailnetName(host) {
		return h.ts.Dial(ctx, "tcp", addr)
	}
	c, err4 := h.ts.Dial(ctx, "tcp4", addr)
	if err4 == nil {
		return c, nil
	}
	if ctx.Err() != nil {
		return nil, err4
	}
	c, err6 := h.ts.Dial(ctx, "tcp6", addr)
	if err6 == nil {
		return c, nil
	}
	return nil, fmt.Errorf("%w (IPv6: %v)", err4, err6)
}

// exitV6Memory: how long an IPv6 "unreachable" through the exit node keeps
// the shell's AAAA answers back for names that leave through it.
const exitV6Memory = 10 * time.Minute

// noteExitIPv6 remembers an IPv6 literal that the exit node could not reach
// at all ("network is unreachable": the path has no IPv6), and forgets it
// once an IPv6 dial through the exit node works again.
func (h *Hub) noteExitIPv6(d Decision, addr string, err error) {
	if d.Rule != "exit-node" {
		return
	}
	host, _, _ := net.SplitHostPort(addr)
	ip, perr := netip.ParseAddr(host)
	if perr != nil || !ip.Unmap().Is6() {
		return
	}
	switch {
	case err == nil:
		h.exitV6Dead.Store(0)
	case Classify(err) == ClassUnreachable:
		if h.exitV6Dead.Swap(time.Now().UnixNano()) == 0 {
			h.logf("[Net][DNS] IPv6 is unreachable through the exit node: the shell gets IPv4 answers only for names that leave through it")
		}
	}
}

// exitV6ProbeAddr is dialed to learn whether IPv6 leaves through the exit
// node at all (Cloudflare's resolver; any reply, even a refusal, says yes).
var exitV6ProbeAddr = "[2606:4700:4700::1111]:443"

// exitIPv6Usable: IPv6 destinations can leave through the exit node in use.
// False when the exit node does not route ::/0, or an IPv6 dial through it
// failed as unreachable within exitV6Memory (FIX-261025-27). An exit node
// can carry ::/0 and still have no IPv6 path from this node - seen on a
// Pixel 6, every IPv6 dial "network is unreachable" in ~30 ms - so without a
// recent answer one IPv6 dial is tried first, and only an "unreachable"
// (not a slow answer) counts against it.
func (h *Hub) exitIPv6Usable() bool {
	if r, ok := h.ts.(ExitIPv6Reporter); ok && !r.ExitNodeIPv6() {
		return false
	}
	if h.exitOffline(Decision{Rule: "exit-node"}) {
		return true // every connection through it fails anyway; nothing to probe
	}
	if at := h.exitV6Dead.Load(); at != 0 {
		return time.Since(time.Unix(0, at)) > exitV6Memory
	}
	now := time.Now().UnixNano()
	if last := h.exitV6Probed.Load(); last != 0 && time.Duration(now-last) < exitV6Memory {
		return true
	}
	if !h.exitV6Probed.CompareAndSwap(h.exitV6Probed.Load(), now) {
		return true // another query is probing
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	c, err := h.ts.Dial(ctx, "tcp6", exitV6ProbeAddr)
	if c != nil {
		c.Close()
	}
	h.noteExitIPv6(Decision{Kind: "tailscale", Rule: "exit-node"}, exitV6ProbeAddr, err)
	return h.exitV6Dead.Load() == 0
}

// describePeer: peer details for a tailnet destination, "" if unknown.
func (h *Hub) describePeer(host string) string {
	if pd, ok := h.ts.(PeerDescriber); ok {
		return pd.DescribePeer(host)
	}
	return ""
}

// DialVia opens a connection for `tag` to addr exactly as a SOCKS client of
// the hub would get it (used for tests and the in-process rclone dialer).
func (h *Hub) DialVia(ctx context.Context, tag, addr string) (net.Conn, Decision, error) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, Decision{}, err
	}
	d := h.Decide(tag, host)
	c, err := h.dial(ctx, d, addr)
	return c, d, err
}

// TestUpstream connects through u to target and reports the elapsed time.
func TestUpstream(u Upstream, target string, timeout time.Duration) (time.Duration, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	t0 := time.Now()
	d := net.Dialer{Timeout: timeout}
	c, err := DialUpstream(ctx, &d, u, target)
	if err != nil {
		return 0, err
	}
	c.Close()
	return time.Since(t0), nil
}

var errAuth = errors.New("authentication failed")

func fmtErr(format string, a ...any) error { return fmt.Errorf(format, a...) }
