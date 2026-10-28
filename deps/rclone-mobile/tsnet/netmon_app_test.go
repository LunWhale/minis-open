package tsnet

import (
	"testing"

	"tailscale.com/net/netmon"
)

func TestSetInterfacesFeedsNetmon(t *testing.T) {
	raw := `[{"name":"wlan0","index":3,"mtu":1500,"up":true,"multicast":true,"broadcast":true,
	          "addrs":["10.0.2.16/24","fe80::1/64","bogus"]},
	         {"name":"lo","index":1,"mtu":65536,"up":true,"loopback":true,"addrs":["127.0.0.1/8"]}]`
	if err := SetInterfaces(raw); err != nil {
		t.Fatal(err)
	}
	list, err := netmon.GetInterfaceList()
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 2 || list[0].Name != "wlan0" || !list[0].IsUp() || !list[1].IsLoopback() {
		t.Fatalf("unexpected list: %+v", list)
	}
	addrs, _ := list[0].Addrs()
	if len(addrs) != 2 || addrs[0].String() != "10.0.2.16/24" {
		t.Fatalf("addrs = %v (an unparsable entry must be skipped)", addrs)
	}
	// An empty list is refused and the previous one kept.
	if err := SetInterfaces(`[]`); err == nil {
		t.Fatal("empty list accepted")
	}
	if list, _ := netmon.GetInterfaceList(); len(list) != 2 {
		t.Fatalf("previous list lost: %d", len(list))
	}
	if err := SetInterfaces(`not json`); err == nil {
		t.Fatal("bad JSON accepted")
	}
	// No node running: a no-op, not a crash.
	NetworkChanged()
}
