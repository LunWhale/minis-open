package tsnet

import (
	"net"
	"net/netip"
	"sync/atomic"
	"time"

	"tailscale.com/net/packet"
	ts "tailscale.com/tsnet"
	"tailscale.com/wgengine/filter"
)

// MARK: - Replies to the node's own UDP (exit node, ACL-restricted peers)
//
// A UDP socket dialed through the node (Server.Dial "udp", a gVisor socket)
// sends its packets with tstun's InjectOutbound, which skips the packet
// filter - so the filter never records the flow, and a reply is then judged
// as a new inbound packet: one from a public address through an exit node
// (8.8.8.8, a STUN server) matches no ACL rule and is dropped ("no rules
// matched"), as is one from a peer the ACLs do not let reach us. TCP is not
// hit (non-SYN packets pass). Tailscale v1.94; a kernel-TUN node records the
// flow on the way out, this does the same: each datagram (at most once a
// second per socket) is run through the filter's outbound side, which adds
// the reversed 5-tuple to the state its inbound side accepts ("cached").

const conntrackRefresh = time.Second

type udpConntrack struct {
	net.Conn
	s        *ts.Server
	src, dst netip.AddrPort
	noted    atomic.Int64 // unix nanos of the last note
}

// trackUDP wraps c, a UDP socket from s.Dial, when it is one of the node's
// own (its local address is a tailnet address of s); others (a peer reached
// through the system's sockets) are returned as they are.
func trackUDP(s *ts.Server, c net.Conn) net.Conn {
	la, ok1 := c.LocalAddr().(*net.UDPAddr)
	ra, ok2 := c.RemoteAddr().(*net.UDPAddr)
	if !ok1 || !ok2 {
		return c
	}
	src, dst := la.AddrPort(), ra.AddrPort()
	src = netip.AddrPortFrom(src.Addr().Unmap(), src.Port())
	dst = netip.AddrPortFrom(dst.Addr().Unmap(), dst.Port())
	ip4, ip6 := s.TailscaleIPs()
	if src.Addr() != ip4 && src.Addr() != ip6 {
		return c
	}
	return &udpConntrack{Conn: c, s: s, src: src, dst: dst}
}

func (u *udpConntrack) Write(b []byte) (int, error) {
	if now := time.Now().UnixNano(); now-u.noted.Load() >= int64(conntrackRefresh) {
		u.noted.Store(now)
		if e, ok := u.s.Sys().Engine.GetOK(); ok {
			noteUDPFlow(e.GetFilter(), u.src, u.dst)
		}
	}
	return u.Conn.Write(b)
}

// noteUDPFlow records src -> dst in f's flow state, so that dst's replies
// to src are accepted.
func noteUDPFlow(f *filter.Filter, src, dst netip.AddrPort) {
	if f == nil || src.Addr().Is4() != dst.Addr().Is4() {
		return
	}
	var h packet.Header
	if src.Addr().Is4() {
		h = packet.UDP4Header{IP4Header: packet.IP4Header{Src: src.Addr(), Dst: dst.Addr()}, SrcPort: src.Port(), DstPort: dst.Port()}
	} else {
		h = packet.UDP6Header{IP6Header: packet.IP6Header{Src: src.Addr(), Dst: dst.Addr()}, SrcPort: src.Port(), DstPort: dst.Port()}
	}
	var p packet.Parsed
	p.Decode(packet.Generate(h, nil))
	f.RunOut(&p, 0)
}
