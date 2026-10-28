package tsnet

import (
	"context"
	"fmt"
	"net/netip"
	"strings"
	"time"

	"golang.org/x/net/dns/dnsmessage"
	"tailscale.com/tailcfg"
)

// Check is one line of the network diagnose screen.
type Check struct {
	Name   string `json:"name"`
	Status string `json:"status"` // pass | fail | warn | skip
	Detail string `json:"detail"`
	Ms     int64  `json:"ms,omitempty"`
}

// Diagnose checks the node: state and login, MagicDNS resolution of an
// online peer, and a disco ping to it (latency + direct / DERP path). It
// never reveals the auth URL or keys.
func Diagnose(timeout time.Duration) []Check {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return []Check{{Name: "tailscale", Status: "skip", Detail: "node not started"}}
	}
	out := []Check{}
	lc, err := s.LocalClient()
	if err != nil {
		return append(out, Check{Name: "tailscale", Status: "fail", Detail: "local client: " + err.Error()})
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	t0 := time.Now()
	st, err := lc.Status(ctx)
	if err != nil {
		return append(out, Check{Name: "tailscale", Status: "fail", Detail: "status: " + err.Error(), Ms: time.Since(t0).Milliseconds()})
	}
	node := Check{Name: "tailscale", Ms: time.Since(t0).Milliseconds()}
	switch st.BackendState {
	case "Running":
		node.Status = "pass"
	case "NeedsLogin", "NeedsMachineAuth":
		node.Status = "fail"
	default:
		node.Status = "warn"
	}
	tailnet := ""
	if st.CurrentTailnet != nil {
		tailnet = st.CurrentTailnet.Name
	}
	ips := []string{}
	for _, ip := range st.TailscaleIPs {
		if ip.Is4() {
			ips = append(ips, ip.String())
		}
	}
	online := 0
	var target *struct {
		name, dns string
		ip        netip.Addr
	}
	for _, p := range st.Peer {
		if !p.Online {
			continue
		}
		online++
		if target == nil && len(p.TailscaleIPs) > 0 {
			target = &struct {
				name, dns string
				ip        netip.Addr
			}{p.HostName, strings.TrimSuffix(p.DNSName, "."), p.TailscaleIPs[0]}
		}
	}
	node.Detail = fmt.Sprintf("state=%s tailnet=%s ip=%s peers online=%d/%d", st.BackendState,
		orDash(tailnet), orDash(strings.Join(ips, ",")), online, len(st.Peer))
	if st.AuthURL != "" {
		node.Detail += " (waiting for login)"
	}
	// Health messages that only describe a deliberate setting (subnet routes
	// off by default) are informational, not a warning.
	warnings, notes := []string{}, []string{}
	for _, h := range st.Health {
		if strings.Contains(h, "accept-routes is false") {
			notes = append(notes, "peers advertise subnet routes; not accepted (Use Subnet Routes is off)")
		} else {
			warnings = append(warnings, h)
		}
	}
	if len(notes) > 0 {
		node.Detail += " note: " + strings.Join(notes, "; ")
	}
	if len(warnings) > 0 {
		node.Detail += " health: " + strings.Join(warnings, "; ")
		if node.Status == "pass" {
			node.Status = "warn"
		}
	}
	out = append(out, node)
	if st.BackendState != "Running" {
		return append(out,
			Check{Name: "magicdns", Status: "skip", Detail: "node not running"},
			Check{Name: "tailnet-ping", Status: "skip", Detail: "node not running"})
	}
	if target == nil {
		return append(out,
			Check{Name: "magicdns", Status: "skip", Detail: "no online peer to resolve"},
			Check{Name: "tailnet-ping", Status: "skip", Detail: "no online peer"})
	}

	// MagicDNS: resolve the peer's name through the node's resolver.
	t0 = time.Now()
	dnsCheck := Check{Name: "magicdns"}
	raw, _, err := lc.QueryDNS(ctx, target.dns+".", "A")
	dnsCheck.Ms = time.Since(t0).Milliseconds()
	if err != nil {
		dnsCheck.Status, dnsCheck.Detail = "fail", fmt.Sprintf("%s: %v", target.dns, err)
	} else {
		var p dnsmessage.Parser
		answers := 0
		if _, perr := p.Start(raw); perr == nil && p.SkipAllQuestions() == nil {
			if as, aerr := p.AllAnswers(); aerr == nil {
				answers = len(as)
			}
		}
		if answers > 0 {
			dnsCheck.Status, dnsCheck.Detail = "pass", fmt.Sprintf("%s -> %d answer(s)", target.dns, answers)
		} else {
			dnsCheck.Status, dnsCheck.Detail = "fail", target.dns+": no answer"
		}
	}
	out = append(out, dnsCheck)

	// Disco ping: is the peer reachable, and over which path?
	t0 = time.Now()
	ping := Check{Name: "tailnet-ping"}
	res, err := lc.Ping(ctx, target.ip, tailcfg.PingDisco)
	ping.Ms = time.Since(t0).Milliseconds()
	switch {
	case err != nil:
		ping.Status, ping.Detail = "fail", fmt.Sprintf("%s (%s): %v", target.name, target.ip, err)
	case res.Err != "":
		ping.Status, ping.Detail = "fail", fmt.Sprintf("%s (%s): %s", target.name, target.ip, res.Err)
	default:
		path := "direct " + res.Endpoint
		if res.Endpoint == "" && res.DERPRegionCode != "" {
			path = "relay DERP " + res.DERPRegionCode
		}
		ping.Status = "pass"
		ping.Detail = fmt.Sprintf("%s (%s) %.0fms via %s", target.name, target.ip, res.LatencySeconds*1000, path)
	}
	return append(out, ping)
}
