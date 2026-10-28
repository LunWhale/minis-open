package nethub

import (
	"net/netip"
	"sort"
	"strings"
)

// MARK: - Route snapshot for transparent forwarding (iSH xnet)
//
// iSH can hand a guest's TCP connect() to this entry by itself, for programs
// that ignore proxy variables (ssh, nc, static binaries). It matches only
// destination addresses against two prefix lists, so the lists must say what
// Decide would say: everything Decide sends somewhere other than "direct"
// is hooked, and the entry then decides again per connection. The lists are
// built here, from the same state Decide reads, so the app never re-derives
// the policy.

// SelfAddresser is optionally implemented by a Tailnet: the node's own
// tailnet addresses (getsockname of a forwarded connection reports them).
type SelfAddresser interface {
	SelfAddrs() []netip.Addr
}

// HookSnapshot is what iSH's ish_xnet_set_routes takes.
type HookSnapshot struct {
	Route      string   `json:"route"`      // the tag's resolved route
	Tailnet    bool     `json:"tailnet"`    // tailnet destinations are hooked
	Everything bool     `json:"everything"` // 0/0 is hooked (exit node or upstream proxy)
	Hook       []string `json:"hook"`
	Exempt     []string `json:"exempt"`
	Self       []string `json:"self"`
	// Stage 2 (ish_xnet_set_routes2). UDPHook: what UDP goes through the
	// entry - Hook, except that a route through an upstream proxy cannot
	// carry UDP, so there only the tailnet prefixes. Resolvers: the shell's
	// nameservers as given; their port 53 is DNS (never treated by the
	// lists). DNSIntercept: send that DNS to the entry (dns.go) - while the
	// node is up, so MagicDNS names resolve; otherwise it goes directly.
	UDPHook      []string `json:"udpHook"`
	Resolvers    []string `json:"resolvers"`
	DNSIntercept bool     `json:"dnsIntercept"`
}

var (
	allV4 = netip.MustParsePrefix("0.0.0.0/0")
	allV6 = netip.MustParsePrefix("::/0")
)

// SplitTag separates a SOCKS / proxy username into the policy tag and an
// optional client connection id: iSH authenticates as "shell~x1f" so both
// logs can name the same connection. Tags never contain '~'.
func SplitTag(user string) (tag, clientID string) {
	if i := strings.IndexByte(user, '~'); i >= 0 {
		return user[:i], user[i+1:]
	}
	return user, ""
}

// HookRoutes returns the snapshot for connections of `tag`, given the
// networks the device is on right now (`local`, e.g. the Wi-Fi subnet).
//
//   - Tailnet prefixes (peers, accepted subnet routes, Tailscale's ranges)
//     are hooked while the node is up, for every route: Decide sends tailnet
//     destinations through the tailnet whatever the route says.
//   - 0/0 is hooked too when the rest of the tag's traffic does not go out
//     directly: route tailscale with an exit node, or an existing upstream
//     proxy.
//   - Local networks are exempt (reachable directly; at home the subnet
//     route to the same LAN would otherwise loop through the tailnet), except
//     tailnet prefixes strictly inside them: the more specific route wins,
//     as in a routing table.
//   - An upstream's address bypass entries are exempt, except where the
//     tailnet covers them: Decide checks the tailnet before the bypass list.
//     Host-name bypass entries cannot be expressed (the hook sees addresses).
func (h *Hub) HookRoutes(tag string, local []netip.Prefix) HookSnapshot {
	return h.HookRoutesWithResolvers(tag, local, nil)
}

// HookRoutesWithResolvers is HookRoutes plus the stage 2 fields, given the
// shell's nameservers (its /etc/resolv.conf).
func (h *Hub) HookRoutesWithResolvers(tag string, local []netip.Prefix, resolvers []netip.Addr) HookSnapshot {
	route := h.routeFor(tag)
	out := HookSnapshot{Route: route, Hook: []string{}, Exempt: []string{}, Self: []string{},
		UDPHook: []string{}, Resolvers: []string{}}
	seen := map[netip.Addr]bool{}
	for _, r := range resolvers {
		if r = r.Unmap(); r.IsValid() && !seen[r] {
			seen[r] = true
			out.Resolvers = append(out.Resolvers, r.String())
		}
	}
	var tailnet []netip.Prefix
	if h.tailscaleUp() {
		out.Tailnet = true
		for _, p := range h.ts.Prefixes() {
			if p.Bits() > 0 {
				tailnet = append(tailnet, p.Masked())
			}
		}
		if sa, ok := h.ts.(SelfAddresser); ok {
			for _, a := range sa.SelfAddrs() {
				out.Self = append(out.Self, a.String())
			}
		}
	}
	var bypass []netip.Prefix
	switch {
	case route == "tailscale":
		out.Everything = out.Tailnet && h.ts.ExitNodeActive()
	case strings.HasPrefix(route, "proxy:"):
		if u := h.upstream(strings.TrimPrefix(route, "proxy:")); u != nil {
			out.Everything = true
			bypass = bypassPrefixes(u.Bypass)
		}
	}
	out.DNSIntercept = out.Tailnet
	hook := append([]netip.Prefix(nil), tailnet...)
	udpHook := append([]netip.Prefix(nil), tailnet...)
	if out.Everything {
		hook = append(hook, allV4, allV6)
		if route == "tailscale" { // an exit node; an upstream proxy carries no UDP
			udpHook = append(udpHook, allV4, allV6)
		}
	}
	out.UDPHook = prefixStrings(udpHook)
	// Nothing is hooked: exemptions would change nothing.
	if len(hook) == 0 {
		return out
	}
	var exempt []netip.Prefix
	for _, l := range local {
		l = l.Masked()
		var inside []netip.Prefix
		for _, t := range tailnet {
			if t.Bits() > l.Bits() && l.Contains(t.Addr()) {
				inside = append(inside, t)
			}
		}
		exempt = append(exempt, subtractPrefixes(l, inside)...)
	}
	for _, b := range bypass {
		covered := false
		var inside []netip.Prefix
		for _, t := range tailnet {
			switch {
			case t.Bits() <= b.Bits() && t.Contains(b.Addr()):
				covered = true
			case t.Bits() > b.Bits() && b.Contains(t.Addr()):
				inside = append(inside, t)
			}
		}
		if !covered {
			exempt = append(exempt, subtractPrefixes(b, inside)...)
		}
	}
	out.Hook = prefixStrings(hook)
	out.Exempt = prefixStrings(exempt)
	return out
}

// bypassPrefixes keeps the address entries of a bypass list (CIDR or IP).
func bypassPrefixes(list []string) []netip.Prefix {
	var out []netip.Prefix
	for _, raw := range list {
		e := strings.TrimSpace(raw)
		if p, err := netip.ParsePrefix(e); err == nil {
			out = append(out, p.Masked())
		} else if a, err := netip.ParseAddr(strings.Trim(e, "[]")); err == nil {
			a = a.Unmap()
			out = append(out, netip.PrefixFrom(a, a.BitLen()))
		}
	}
	return out
}

// subtractPrefixes returns `a` minus every prefix in holes (each inside a),
// as a list of prefixes. Splits `a` in halves until no half partly overlaps
// a hole, so the result has at most (hole bits - a bits) prefixes per hole.
func subtractPrefixes(a netip.Prefix, holes []netip.Prefix) []netip.Prefix {
	overlaps := false
	for _, h := range holes {
		if h.Bits() <= a.Bits() && h.Contains(a.Addr()) {
			return nil // a hole covers all of a
		}
		if h.Bits() > a.Bits() && a.Contains(h.Addr()) {
			overlaps = true
		}
	}
	if !overlaps {
		return []netip.Prefix{a}
	}
	lo, hi := halves(a)
	return append(subtractPrefixes(lo, holes), subtractPrefixes(hi, holes)...)
}

// halves splits a prefix into its two children (a.Bits() < bit length).
func halves(a netip.Prefix) (netip.Prefix, netip.Prefix) {
	bits := a.Bits() + 1
	lo := netip.PrefixFrom(a.Addr(), bits).Masked()
	b := lo.Addr().AsSlice()
	idx := a.Bits()
	b[idx/8] |= 0x80 >> (idx % 8)
	hiAddr, _ := netip.AddrFromSlice(b)
	return lo, netip.PrefixFrom(hiAddr, bits)
}

func prefixStrings(ps []netip.Prefix) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, p := range ps {
		if k := p.String(); !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}
