package tsnet

import (
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"sync"

	"tailscale.com/net/netmon"
)

// The app-fed view of the OS network, for platforms where Go cannot read it
// itself.
//
// Android: since API 30 an app may not bind a NETLINK_ROUTE socket, so Go's
// net.Interfaces() fails ("netlinkrib: permission denied") and tailscale's
// netmon would see no interfaces at all. netmon's Android build already polls
// instead of using netlink (netmon_polling.go) and takes the default
// interface from the app (UpdateLastKnownDefaultRouteInterface); what it
// still needs is the interface list, through RegisterInterfaceGetter. The
// app reads it from java.net.NetworkInterface, which goes through a
// permitted path, and pushes it here on every ConnectivityManager callback,
// then NetworkChanged wakes the monitor instead of waiting for its 10-minute
// poll. This is what Tailscale's own Android app does (libtailscale).
//
// iOS never calls these: netmon reads interfaces and routes itself there.

// AppInterface is one interface as the app reports it.
type AppInterface struct {
	Name      string   `json:"name"`
	Index     int      `json:"index"`
	MTU       int      `json:"mtu"`
	Up        bool     `json:"up"`
	Loopback  bool     `json:"loopback"`
	P2P       bool     `json:"p2p"`
	Multicast bool     `json:"multicast"`
	Broadcast bool     `json:"broadcast"`
	Addrs     []string `json:"addrs"` // "ip/prefixLen"
}

var (
	ifMu       sync.Mutex
	ifList     []netmon.Interface
	ifGetterOn bool
)

// SetInterfaces replaces the app-reported interface list (JSON array of
// AppInterface) and, the first time, makes netmon read interfaces from it.
func SetInterfaces(raw string) error {
	var in []AppInterface
	if err := json.Unmarshal([]byte(raw), &in); err != nil {
		return err
	}
	if len(in) == 0 {
		// An empty list would make netmon believe the device is offline for
		// good; the OS view is then simply unknown, keep the previous one.
		return errors.New("tsnet: empty interface list")
	}
	list := make([]netmon.Interface, 0, len(in))
	for _, a := range in {
		var flags net.Flags
		if a.Up {
			flags |= net.FlagUp | net.FlagRunning
		}
		if a.Loopback {
			flags |= net.FlagLoopback
		}
		if a.P2P {
			flags |= net.FlagPointToPoint
		}
		if a.Multicast {
			flags |= net.FlagMulticast
		}
		if a.Broadcast {
			flags |= net.FlagBroadcast
		}
		addrs := []net.Addr{}
		for _, s := range a.Addrs {
			p, err := netip.ParsePrefix(s)
			if err != nil {
				continue
			}
			addrs = append(addrs, &net.IPNet{IP: p.Addr().AsSlice(), Mask: net.CIDRMask(p.Bits(), p.Addr().BitLen())})
		}
		list = append(list, netmon.Interface{
			Interface: &net.Interface{Index: a.Index, MTU: a.MTU, Name: a.Name, Flags: flags},
			AltAddrs:  addrs,
		})
	}
	ifMu.Lock()
	ifList = list
	first := !ifGetterOn
	ifGetterOn = true
	ifMu.Unlock()
	if first {
		netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
			ifMu.Lock()
			defer ifMu.Unlock()
			out := make([]netmon.Interface, len(ifList))
			copy(out, ifList)
			return out, nil
		})
	}
	return nil
}

// NetworkChanged tells a running node's network monitor that the OS network
// changed (default interface, addresses), so it re-reads state now instead
// of at its next poll. A no-op while the node is stopped.
func NetworkChanged() {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return
	}
	if nm, ok := s.Sys().NetMon.GetOK(); ok && nm != nil {
		nm.InjectEvent()
	}
}
