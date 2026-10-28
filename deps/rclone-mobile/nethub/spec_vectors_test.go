package nethub

import (
	"encoding/json"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
)

// [FEAT-261021-14 G7] The routing vectors of the shared spec
// (src/shared/network/route_vectors.json) against this router. Every
// platform's router must give the same decisions; this keeps the spec and
// the Go implementation from drifting.
func TestSharedSpecRouteVectors(t *testing.T) {
	path := filepath.Join("..", "..", "..", "src", "shared", "network", "route_vectors.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var file struct {
		Cases []struct {
			Name   string `json:"name"`
			Config Config `json:"config"`
			Node   struct {
				Running  bool     `json:"running"`
				ExitNode bool     `json:"exitNode"`
				Prefixes []string `json:"prefixes"`
				Suffix   string   `json:"magicDNSSuffix"`
			} `json:"node"`
			Tag  string `json:"tag"`
			Host string `json:"host"`
			Want struct {
				Kind string `json:"kind"`
				Rule string `json:"rule"`
			} `json:"want"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	if len(file.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range file.Cases {
		ts := &fakeTailnet{running: c.Node.Running, exitNode: c.Node.ExitNode, suffix: c.Node.Suffix}
		for _, p := range c.Node.Prefixes {
			ts.prefixes = append(ts.prefixes, netip.MustParsePrefix(p))
		}
		h := New(ts, nil)
		h.Configure(c.Config)
		d := h.Decide(c.Tag, c.Host)
		if d.Kind != c.Want.Kind || d.Rule != c.Want.Rule {
			t.Errorf("%s: got kind=%s rule=%s, want kind=%s rule=%s", c.Name, d.Kind, d.Rule, c.Want.Kind, c.Want.Rule)
		}
	}
	t.Logf("%d vectors", len(file.Cases))
}
