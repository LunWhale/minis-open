package tsnet

import (
	"net/netip"
	"testing"

	"go4.org/netipx"
	"tailscale.com/net/packet"
	"tailscale.com/wgengine/filter"
)

func udpPacket(src, dst netip.AddrPort) *packet.Parsed {
	var h packet.Header
	if src.Addr().Is4() {
		h = packet.UDP4Header{IP4Header: packet.IP4Header{Src: src.Addr(), Dst: dst.Addr()}, SrcPort: src.Port(), DstPort: dst.Port()}
	} else {
		h = packet.UDP6Header{IP6Header: packet.IP6Header{Src: src.Addr(), Dst: dst.Addr()}, SrcPort: src.Port(), DstPort: dst.Port()}
	}
	var p packet.Parsed
	p.Decode(packet.Generate(h, []byte("x")))
	return &p
}

// A reply from a public address (through an exit node) is dropped by a
// filter with no rule for it until the outbound flow is noted.
func TestNoteUDPFlowAcceptsReplies(t *testing.T) {
	for _, tc := range []struct{ self, remote string }{
		{"100.64.0.43:40000", "8.8.8.8:53"},
		{"[fd7a:115c:a1e0::fa39:650f]:40000", "[2001:4860:4860::8888]:53"},
	} {
		self, remote := netip.MustParseAddrPort(tc.self), netip.MustParseAddrPort(tc.remote)
		var sb netipx.IPSetBuilder
		sb.Add(self.Addr())
		local, _ := sb.IPSet()
		f := filter.New(nil, nil, local, local, nil, t.Logf)

		reply := udpPacket(remote, self)
		if r := f.RunIn(reply, 0); r != filter.Drop {
			t.Fatalf("%s: reply before the flow is noted = %v, want Drop", tc.remote, r)
		}
		noteUDPFlow(f, self, remote)
		if r := f.RunIn(udpPacket(remote, self), 0); r != filter.Accept {
			t.Fatalf("%s: reply after the flow is noted = %v, want Accept", tc.remote, r)
		}
		other := netip.AddrPortFrom(self.Addr(), self.Port()+1)
		if r := f.RunIn(udpPacket(remote, other), 0); r != filter.Drop {
			t.Fatalf("%s: reply to another port = %v, want Drop", tc.remote, r)
		}
	}
	noteUDPFlow(nil, netip.MustParseAddrPort("100.1.1.1:1"), netip.MustParseAddrPort("8.8.8.8:53")) // no filter yet: no-op
}
