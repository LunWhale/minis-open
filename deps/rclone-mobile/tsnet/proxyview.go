package tsnet

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"sort"
	"strings"
	"sync"
	"time"
)

// MARK: - Routing view for the local proxy (nethub.Tailnet)
//
// The local proxy asks this view, for EVERY connection, whether the
// destination belongs to the tailnet. It must therefore never block on the
// node: a node that is starting, logged out or wedged would otherwise add
// seconds to unrelated (direct / upstream proxy) connections. The view
// returns the last snapshot at once; a background goroutine refreshes it
// every routeCacheTTL, and immediately after start / stop / pref changes.
//
// Each refresh also logs what changed - backend state, peers online, exit
// node, accepted subnet routes, health warnings - under [Net][TS], so a
// user log shows the node's history next to the connection lines.

type peerBrief struct {
	name   string
	online bool
	path   string // "direct <ip:port>", "relay <region>", "idle"
}

type routeCache struct {
	at       time.Time
	running  bool
	state    string
	prefixes []netip.Prefix
	exit     bool
	accept   bool
	self     []netip.Addr // this node's tailnet addresses
	suffix   string
	short    map[string]bool       // peers' first DNS label, for bare MagicDNS names
	peers    map[string]*peerBrief // by Tailscale IP, full DNS name and short name
	online   int
	total    int
	health   string
}

var (
	cacheMu     sync.Mutex
	cache       routeCache
	refreshKick = make(chan struct{}, 1)
	refreshOnce sync.Once
)

const routeCacheTTL = 5 * time.Second

func startRefresher() {
	refreshOnce.Do(func() {
		go func() {
			t := time.NewTicker(routeCacheTTL)
			defer t.Stop()
			for {
				select {
				case <-refreshKick:
				case <-t.C:
				}
				refreshRoutes()
			}
		}()
	})
}

// invalidateRouteCache asks for a refresh now (non-blocking).
func invalidateRouteCache() {
	startRefresher()
	select {
	case refreshKick <- struct{}{}:
	default:
	}
}

// currentRoutes returns the latest snapshot without ever touching the node.
func currentRoutes() routeCache {
	startRefresher()
	cacheMu.Lock()
	c := cache
	cacheMu.Unlock()
	if time.Since(c.at) > 2*routeCacheTTL {
		invalidateRouteCache()
	}
	return c
}

func refreshRoutes() {
	next := routeCache{at: time.Now(), short: map[string]bool{}, peers: map[string]*peerBrief{}, state: "Stopped"}
	mu.Lock()
	s := srv
	mu.Unlock()
	if s != nil {
		next.state = "Starting"
		if lc, err := s.LocalClient(); err == nil {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			st, err := lc.Status(ctx)
			accept := false
			if prefs, perr := lc.GetPrefs(ctx); perr == nil {
				accept = prefs.RouteAll
			}
			cancel()
			if err != nil {
				next.state = "StatusError"
				Logf("[Net][TS] status unavailable: %v (tailnet destinations follow their route until it answers)", err)
			} else {
				next.state = st.BackendState
				next.running = st.BackendState == "Running"
				r := buildRoutes(st, accept)
				for _, p := range r.Prefixes {
					if pp, err := netip.ParsePrefix(p); err == nil && pp.Bits() > 0 {
						next.prefixes = append(next.prefixes, pp)
					}
				}
				next.exit, next.accept, next.suffix = r.ExitNode, r.AcceptRoutes, r.MagicDNSSuffix
				next.self = append([]netip.Addr(nil), st.TailscaleIPs...)
				if st.Self != nil {
					if label, _, _ := strings.Cut(st.Self.DNSName, "."); label != "" {
						next.short[strings.ToLower(label)] = true
					}
				}
				for _, p := range st.Peer {
					next.total++
					if p.Online {
						next.online++
					}
					label, _, _ := strings.Cut(p.DNSName, ".")
					b := &peerBrief{name: label, online: p.Online, path: "idle"}
					if b.name == "" {
						b.name = p.HostName
					}
					switch {
					case p.CurAddr != "":
						b.path = "direct " + p.CurAddr
					case p.Relay != "":
						b.path = "relay " + p.Relay
					}
					for _, ip := range p.TailscaleIPs {
						next.peers[ip.String()] = b
					}
					if label != "" {
						next.short[strings.ToLower(label)] = true
						next.peers[strings.ToLower(label)] = b
						next.peers[strings.ToLower(strings.TrimSuffix(p.DNSName, "."))] = b
					}
				}
				if len(st.Health) > 0 {
					h := append([]string(nil), st.Health...)
					sort.Strings(h)
					next.health = strings.Join(h, "; ")
				}
			}
		}
	}
	cacheMu.Lock()
	prev := cache
	cache = next
	cacheMu.Unlock()
	logTransitions(prev, next)
}

func logTransitions(prev, next routeCache) {
	if prev.state != next.state {
		Logf("[Net][TS] state %s -> %s", orDash(prev.state), next.state)
	}
	if next.running && (prev.online != next.online || prev.total != next.total) {
		Logf("[Net][TS] peers online %d/%d", next.online, next.total)
	}
	if prev.exit != next.exit {
		Logf("[Net][TS] exit node in use = %v", next.exit)
	}
	if prev.accept != next.accept && next.state != "Stopped" {
		Logf("[Net][TS] subnet routes accepted = %v (%d prefixes routed to the tailnet)", next.accept, len(next.prefixes))
	}
	if prev.health != next.health && next.health != "" {
		Logf("[Net][TS] health: %s", next.health)
	}
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// ProxyView is the node as the local proxy sees it.
type ProxyView struct{}

func (ProxyView) Running() bool            { return currentRoutes().running }
func (ProxyView) Prefixes() []netip.Prefix { return currentRoutes().prefixes }
func (ProxyView) ExitNodeActive() bool     { return currentRoutes().exit }

// SelfAddrs (nethub.SelfAddresser): this node's tailnet addresses.
func (ProxyView) SelfAddrs() []netip.Addr { return currentRoutes().self }
func (ProxyView) Dial(ctx context.Context, n, a string) (net.Conn, error) {
	return Dial(ctx, n, a)
}

// QueryDNS (nethub.DNSQuerier): the node's resolver, see QueryDNS.
// A bare short name ("nas") is asked as its MagicDNS name, see qualifyShortName.
func (ProxyView) QueryDNS(ctx context.Context, query []byte, tcp bool) ([]byte, error) {
	r := currentRoutes()
	q, restore := qualifyShortName(query, r.suffix, r.short)
	answer, err := QueryDNS(ctx, q, tcp)
	if err != nil || restore == nil {
		return answer, err
	}
	return restore(answer), nil
}
func (ProxyView) IsTailnetName(host string) bool {
	r := currentRoutes()
	h := strings.ToLower(strings.TrimSuffix(host, "."))
	if r.suffix != "" && (h == r.suffix || strings.HasSuffix(h, "."+r.suffix)) {
		return true
	}
	// A bare MagicDNS short name ("nas") of a known peer.
	return !strings.Contains(h, ".") && r.short[h]
}

// DescribePeer (nethub.PeerDescriber): "name online direct 1.2.3.4:41641",
// for dial logs; "" when the host is not a known peer.
func (ProxyView) DescribePeer(host string) string {
	r := currentRoutes()
	b := r.peers[strings.ToLower(strings.TrimSuffix(host, "."))]
	if b == nil {
		if !r.running {
			return "node " + orDash(r.state)
		}
		return ""
	}
	status := "offline"
	if b.online {
		status = "online"
	}
	return fmt.Sprintf("%s %s %s", b.name, status, b.path)
}
