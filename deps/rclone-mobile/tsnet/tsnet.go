// Package tsnet runs an embedded Tailscale node (tailscale.com/tsnet) inside
// the same Go c-archive as rclone, so the app links one Go runtime.
//
// It exposes what the app's network module needs: start / stop, status as
// JSON, a dialer, the tailnet routing table (so callers never hard-code
// 100.64.0.0/10), a local SOCKS5 proxy with username/password
// authentication, and the default-route hint the app's NWPathMonitor feeds.
//
// Log upload to log.tailscale.com is OFF: the iOS and Android builds pass
// ts_omit_logtail, and Start sets TS_NO_LOGS_NO_SUPPORT for any build that
// does not.
package tsnet

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"tailscale.com/feature/buildfeatures"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/net/netmon"
	"tailscale.com/net/socks5"
	ts "tailscale.com/tsnet"
)

var (
	mu    sync.Mutex
	srv   *ts.Server
	socks net.Listener

	logMu   sync.Mutex
	logSink func(string)
)

// SetLogger routes the node's log lines to fn (nil = drop). Lines carrying
// an auth key are never produced by this package; tailscale itself does not
// log keys.
func SetLogger(fn func(string)) {
	logMu.Lock()
	logSink = fn
	logMu.Unlock()
}

// loginLink matches the bearer-like interactive login URL; tsnet prints it
// every few seconds while waiting. It never reaches the log sink.
var loginLink = regexp.MustCompile(`(login\.tailscale\.com/a/)[A-Za-z0-9]+`)

func logf(format string, args ...any) {
	logMu.Lock()
	fn := logSink
	logMu.Unlock()
	if fn != nil {
		fn(loginLink.ReplaceAllString(fmt.Sprintf(format, args...), "${1}<redacted>"))
	}
}

// backendLogf filters tailscale's own (unleveled, very chatty) log: only
// lines that help locate a connectivity problem are kept - state changes,
// health, control-plane and login, link / netmon changes, DERP and netcheck,
// and anything reporting an error - and each kind at most once per 30 s.
// Everything is prefixed [Net][TS].
var (
	tsKeep = []string{"Switching ipn state", "health(", "control:", "controlclient", "LinkChange", "link state",
		"network monitor", "netmon", "derp", "netcheck: report", "magicsock: endpoints changed", "[unexpected]",
		"error", "Error", "fail", "denied", "To start this tsnet server", "login", "NeedsLogin", "Bringing"}
	tsDrop      = []string{"wg: [v2]", "Accept: ", "open-conn-track", "[v1] ", "[v2] "}
	tsRateMu    sync.Mutex
	tsRateLast  = map[string]time.Time{}
	tsRateEvery = 30 * time.Second
)

func backendLogf(format string, args ...any) {
	line := fmt.Sprintf(format, args...)
	// A failed login round trip is only reported at [v1] ("WaitLoginURL:
	// register request: http 410 ..."), and without it a sign-in that the
	// browser called successful but the node never saw cannot be explained.
	// It goes through the same 30 s limit: tailscale retries it with backoff.
	loginErr := strings.Contains(line, "[v1] WaitLoginURL") || strings.Contains(line, "[v1] TryLogin")
	for _, d := range tsDrop {
		if !loginErr && strings.Contains(line, d) {
			return
		}
	}
	keep := loginErr
	for _, k := range tsKeep {
		if strings.Contains(line, k) {
			keep = true
			break
		}
	}
	if !keep {
		return
	}
	key := line
	if len(key) > 48 {
		key = key[:48]
	}
	now := time.Now()
	tsRateMu.Lock()
	if t, ok := tsRateLast[key]; ok && now.Sub(t) < tsRateEvery {
		tsRateMu.Unlock()
		return
	}
	if len(tsRateLast) > 256 {
		tsRateLast = map[string]time.Time{}
	}
	tsRateLast[key] = now
	tsRateMu.Unlock()
	logf("[Net][TS] ts: %s", line)
}

// SetDefaultRouteInterface forwards the OS's current default interface
// (from NWPathMonitor) to netmon; on Darwin netmon prefers it over the
// routing-table guess, so Wi-Fi <-> cellular switches are picked up at once.
func SetDefaultRouteInterface(ifName string) {
	netmon.UpdateLastKnownDefaultRouteInterface(ifName)
}

// Start brings the node up. authKey may be empty: the node then waits for an
// interactive login and Status reports the AuthURL. stateDir must exist.
func Start(authKey, hostname, stateDir string) error {
	mu.Lock()
	defer mu.Unlock()
	if srv != nil {
		return nil
	}
	// Never upload logs (logpolicy then uses a no-op transport); envknob
	// reads it when the node starts. Only in a build that has log upload at
	// all: the app builds pass ts_omit_logtail, so they never touch the
	// process environment. With cgo os.Setenv is C setenv, which reallocates
	// environ under any thread reading it: set from this package's init(),
	// it ran on the Go runtime's thread while the app's main thread started
	// up, and JavaScriptCore walking environ for its JSC_* options read a
	// stale entry and crashed the app at launch (crash point
	// DuiHLbR5LJLQEkIH5Mp4xj). Start itself runs during launch too when the
	// user has Tailscale on.
	if buildfeatures.HasLogTail && os.Getenv("TS_NO_LOGS_NO_SUPPORT") == "" {
		os.Setenv("TS_NO_LOGS_NO_SUPPORT", "true")
	}
	s := &ts.Server{
		Hostname: hostname,
		Dir:      stateDir,
		AuthKey:  authKey,
		Logf:     backendLogf,
		UserLogf: backendLogf,
	}
	t0 := time.Now()
	if err := s.Start(); err != nil {
		s.Close()
		// Typical causes: the state file is unreadable (device locked with
		// NSFileProtectionComplete), netmon could not open its route socket.
		logf("[Net][TS] start FAILED after %dms hostname=%s: %v (non-tailnet traffic is unaffected)",
			time.Since(t0).Milliseconds(), hostname, err)
		return err
	}
	srv = s
	invalidateRouteCache()
	logf("[Net][TS] started in %dms hostname=%s authKey=%s", time.Since(t0).Milliseconds(), hostname,
		map[bool]string{true: "provided", false: "none"}[authKey != ""])
	return nil
}

// Stop closes the SOCKS listener (if any) and the node. The state file stays,
// so the next Start logs back in without the user.
func Stop() error {
	mu.Lock()
	defer mu.Unlock()
	if socks != nil {
		socks.Close()
		socks = nil
	}
	if srv == nil {
		return nil
	}
	err := srv.Close()
	srv = nil
	invalidateRouteCache()
	logf("[Net][TS] stopped")
	return err
}

// SetAcceptRoutes turns acceptance of peers' subnet routes on or off
// (Prefs.RouteAll). Tailscale's default is ON, which would send dials to a
// LAN some peer advertises (often the user's own LAN) into the tailnet; the
// app applies its own setting, default off, right after Start.
func SetAcceptRoutes(on bool) error {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return errors.New("tsnet: not started")
	}
	lc, err := s.LocalClient()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err = lc.EditPrefs(ctx, &ipn.MaskedPrefs{Prefs: ipn.Prefs{RouteAll: on}, RouteAllSet: true})
	if err == nil {
		logf("[Net][TS] accept subnet routes = %v", on)
		invalidateRouteCache()
	}
	return err
}

// Logout signs the node out of the tailnet (the state is invalidated on the
// control server), then stops it.
func Logout() error {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s != nil {
		if lc, err := s.LocalClient(); err == nil {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			err = lc.Logout(ctx)
			cancel()
			if err != nil {
				logf("[Net][TS] logout: %v", err)
			}
		}
	}
	return Stop()
}

type peerJSON struct {
	HostName     string   `json:"hostName"`
	DNSName      string   `json:"dnsName"`
	OS           string   `json:"os,omitempty"`
	TailscaleIPs []string `json:"tailscaleIPs"`
	Online       bool     `json:"online"`
	ExitNode     bool     `json:"exitNode,omitempty"`
	ExitOption   bool     `json:"exitNodeOption,omitempty"`
}

type statusJSON struct {
	Running        bool       `json:"running"`
	BackendState   string     `json:"backendState,omitempty"`
	AuthURL        string     `json:"authURL,omitempty"`
	TailscaleIPs   []string   `json:"tailscaleIPs,omitempty"`
	DNSName        string     `json:"dnsName,omitempty"`
	MagicDNSSuffix string     `json:"magicDNSSuffix,omitempty"`
	Tailnet        string     `json:"tailnet,omitempty"`
	Peers          []peerJSON `json:"peers"`
	Socks          string     `json:"socks,omitempty"`
	Error          string     `json:"error,omitempty"`
	// Health is tailscale's own warnings, e.g. "You are logged out. The
	// last login error was: register request: http 410: auth path not
	// found" - the only place a dead sign-in URL shows.
	Health []string `json:"health,omitempty"`
}

// StatusJSON reports the node state; it never fails, errors go in "error".
func StatusJSON() string {
	mu.Lock()
	s, ln := srv, socks
	mu.Unlock()
	out := statusJSON{Peers: []peerJSON{}}
	if s == nil {
		return marshal(out)
	}
	out.Running = true
	if ln != nil {
		out.Socks = ln.Addr().String()
	}
	lc, err := s.LocalClient()
	if err != nil {
		out.Error = err.Error()
		return marshal(out)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	st, err := lc.Status(ctx)
	if err != nil {
		out.Error = err.Error()
		return marshal(out)
	}
	out.BackendState = st.BackendState
	out.AuthURL = st.AuthURL
	out.Health = st.Health
	for _, ip := range st.TailscaleIPs {
		out.TailscaleIPs = append(out.TailscaleIPs, ip.String())
	}
	if st.Self != nil {
		out.DNSName = st.Self.DNSName
	}
	if st.CurrentTailnet != nil {
		out.Tailnet = st.CurrentTailnet.Name
		out.MagicDNSSuffix = st.CurrentTailnet.MagicDNSSuffix
	}
	for _, p := range st.Peer {
		pj := peerJSON{HostName: p.HostName, DNSName: p.DNSName, OS: p.OS, Online: p.Online,
			ExitNode: p.ExitNode, ExitOption: p.ExitNodeOption, TailscaleIPs: []string{}}
		for _, ip := range p.TailscaleIPs {
			pj.TailscaleIPs = append(pj.TailscaleIPs, ip.String())
		}
		out.Peers = append(out.Peers, pj)
	}
	return marshal(out)
}

type routesJSON struct {
	// Prefixes reachable through the tailnet right now: peer addresses,
	// subnet routes the user accepted, and 0.0.0.0/0 + ::/0 while an exit
	// node is in use. Callers route by longest match against this list.
	Prefixes []string `json:"prefixes"`
	// Suffix of MagicDNS names (e.g. "tail1234.ts.net"); names under it
	// always go through the tailnet.
	MagicDNSSuffix string `json:"magicDNSSuffix,omitempty"`
	ExitNode       bool   `json:"exitNode"`
	// ExitIPv6: the exit node in use routes ::/0 (its allowed IPs carry
	// it). Without it an IPv6 destination fails at once through the exit
	// node while IPv4 works (FIX-261025-27).
	ExitIPv6 bool `json:"exitIPv6,omitempty"`
	// ExitOnline: the exit node in use is online. While it is not, the node
	// sends public addresses out through the system network instead
	// (tsdial's SystemDial), so callers must refuse them (FIX-261025-27).
	ExitOnline bool `json:"exitOnline,omitempty"`
	// Whether subnet routes advertised by peers are accepted (RouteAll).
	AcceptRoutes bool `json:"acceptRoutes"`
}

// RoutesJSON returns the dynamic routing table the app's proxy uses to decide
// which connections go through the tailnet.
func RoutesJSON() string {
	mu.Lock()
	s := srv
	mu.Unlock()
	out := routesJSON{Prefixes: []string{}}
	if s == nil {
		return marshal(out)
	}
	lc, err := s.LocalClient()
	if err != nil {
		return marshal(out)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	st, err := lc.Status(ctx)
	if err != nil {
		return marshal(out)
	}
	// Subnet routes only count when this node accepts them (RouteAll, off by
	// default): a peer advertising e.g. 10.1.1.0/24 must not pull the user's
	// own LAN into the tailnet unless they opted in.
	acceptRoutes := false
	if prefs, err := lc.GetPrefs(ctx); err == nil {
		acceptRoutes = prefs.RouteAll
	}
	out = buildRoutes(st, acceptRoutes)
	return marshal(out)
}

// buildRoutes computes the routing table from a status snapshot.
func buildRoutes(st *ipnstate.Status, acceptRoutes bool) routesJSON {
	out := routesJSON{Prefixes: []string{}}
	seen := map[string]bool{}
	add := func(p netip.Prefix) {
		if k := p.Masked().String(); !seen[k] {
			seen[k] = true
			out.Prefixes = append(out.Prefixes, k)
		}
	}
	// Tailscale's own address ranges always belong to the tailnet, so a dial
	// to an offline peer fails inside the tailnet instead of leaking direct.
	add(netip.MustParsePrefix("100.64.0.0/10"))
	add(netip.MustParsePrefix("fd7a:115c:a1e0::/48"))
	for _, p := range st.Peer {
		for _, ip := range p.TailscaleIPs {
			add(netip.PrefixFrom(ip, ip.BitLen()))
		}
		if acceptRoutes && p.Online && p.PrimaryRoutes != nil {
			for _, r := range p.PrimaryRoutes.All() {
				add(r)
			}
		}
		if p.ExitNode {
			out.ExitNode = true
			out.ExitOnline = p.Online
			if p.AllowedIPs != nil {
				for _, r := range p.AllowedIPs.All() {
					if r.Bits() == 0 && r.Addr().Is6() {
						out.ExitIPv6 = true
					}
				}
			}
		}
	}
	out.AcceptRoutes = acceptRoutes
	if out.ExitNode {
		add(netip.MustParsePrefix("0.0.0.0/0"))
		add(netip.MustParsePrefix("::/0"))
	}
	if st.CurrentTailnet != nil {
		out.MagicDNSSuffix = strings.TrimSuffix(st.CurrentTailnet.MagicDNSSuffix, ".")
	}
	return out
}

// Dial opens a connection through the tailnet ("tcp", "100.x.y.z:22" or a
// MagicDNS name).
func Dial(ctx context.Context, network, addr string) (net.Conn, error) {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return nil, errors.New("tsnet: not started")
	}
	c, err := s.Dial(ctx, network, addr)
	if err != nil || !strings.HasPrefix(network, "udp") {
		return c, err
	}
	return trackUDP(s, c), nil
}

// QueryDNS answers a raw DNS query with the node's own resolver - what
// 100.100.100.100 answers: MagicDNS names and tailnet short names, and
// with an exit node in use, the other names through the exit node. The
// query goes in and the answer comes out as they are (same ID). tcp says
// how the client asked: a UDP answer that does not fit is truncated.
func QueryDNS(ctx context.Context, query []byte, tcp bool) ([]byte, error) {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return nil, errors.New("tsnet: not started")
	}
	m, ok := s.Sys().DNSManager.GetOK()
	if !ok {
		return nil, errors.New("tsnet: the node has no DNS manager yet")
	}
	family := "udp"
	if tcp {
		family = "tcp"
	}
	return m.Query(ctx, query, family, netip.MustParseAddrPort("127.0.0.1:0"))
}

type socksJSON struct {
	Addr     string `json:"addr"`
	Username string `json:"username"`
	Password string `json:"password"`
}

// ListenSocks starts a local SOCKS5 proxy on addr (e.g. "127.0.0.1:0") that
// dials through the tailnet. It always requires username/password auth; the
// credentials are generated here and returned with the bound address.
func ListenSocks(addr string) (string, error) {
	mu.Lock()
	defer mu.Unlock()
	if srv == nil {
		return "", errors.New("tsnet: not started")
	}
	if socks != nil {
		return "", fmt.Errorf("tsnet: SOCKS already listening on %s", socks.Addr())
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return "", err
	}
	creds := socksJSON{Addr: ln.Addr().String(), Username: "minis", Password: randomHex(16)}
	s := srv
	server := &socks5.Server{
		Logf:     func(string, ...any) {},
		Dialer:   s.Dial,
		Username: creds.Username,
		Password: creds.Password,
	}
	socks = ln
	go server.Serve(ln)
	return marshal(creds), nil
}

// DialTest dials addr through the tailnet and reports how long it took.
func DialTest(addr string, timeout time.Duration) (time.Duration, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	t0 := time.Now()
	c, err := Dial(ctx, "tcp", addr)
	if err != nil {
		return 0, err
	}
	c.Close()
	return time.Since(t0), nil
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func marshal(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// MARK: - Exit node

// SetExitNode routes all of the node's non-tailnet traffic through the peer
// with Tailscale IP ip ("" turns the exit node off). LAN access stays
// allowed so local devices remain reachable directly.
func SetExitNode(ip string) error {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return errors.New("tsnet: not started")
	}
	lc, err := s.LocalClient()
	if err != nil {
		return err
	}
	mp := &ipn.MaskedPrefs{ExitNodeIPSet: true, ExitNodeIDSet: true, ExitNodeAllowLANAccessSet: true}
	mp.ExitNodeAllowLANAccess = true
	if ip != "" {
		addr, err := netip.ParseAddr(ip)
		if err != nil {
			return err
		}
		mp.ExitNodeIP = addr
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err = lc.EditPrefs(ctx, mp)
	if err == nil {
		logf("[Net][TS] exit node = %q", ip)
		invalidateRouteCache()
	}
	return err
}

// Logf writes to the node's log sink (shared with the local proxy).
func Logf(format string, args ...any) { logf(format, args...) }
