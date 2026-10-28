package tsnet

import (
	"testing"

	"golang.org/x/net/dns/dnsmessage"
)

func dnsQuery(t *testing.T, name string) []byte {
	t.Helper()
	m := dnsmessage.Message{Header: dnsmessage.Header{ID: 0x1234, RecursionDesired: true},
		Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName(name), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
	b, err := m.Pack()
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestQualifyShortName(t *testing.T) {
	short := map[string]bool{"nas": true}
	const suffix = "tail1234.ts.net"

	q, restore := qualifyShortName(dnsQuery(t, "NAS."), suffix, short)
	if restore == nil {
		t.Fatal("short name not qualified")
	}
	var m dnsmessage.Message
	if err := m.Unpack(q); err != nil || m.Header.ID != 0x1234 || m.Questions[0].Name.String() != "nas.tail1234.ts.net." {
		t.Fatalf("rewritten query = %v %v", m.Questions, err)
	}

	// The node's answer for the full name comes back under the asked name.
	m.Response = true
	m.Answers = []dnsmessage.Resource{{
		Header: dnsmessage.ResourceHeader{Name: m.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 600},
		Body:   &dnsmessage.AResource{A: [4]byte{100, 64, 0, 7}},
	}}
	ans, _ := m.Pack()
	var a dnsmessage.Message
	if err := a.Unpack(restore(ans)); err != nil {
		t.Fatal(err)
	}
	if a.Questions[0].Name.String() != "NAS." || a.Answers[0].Header.Name.String() != "NAS." || a.Header.ID != 0x1234 {
		t.Fatalf("restored answer: q=%v an=%v", a.Questions, a.Answers)
	}
	if ip := a.Answers[0].Body.(*dnsmessage.AResource).A; ip != [4]byte{100, 64, 0, 7} {
		t.Fatalf("A = %v", ip)
	}

	for _, name := range []string{"example.com.", "nas.tail1234.ts.net.", "printer."} {
		in := dnsQuery(t, name)
		if out, r := qualifyShortName(in, suffix, short); r != nil || string(out) != string(in) {
			t.Fatalf("%s: rewritten, want as is", name)
		}
	}
	if _, r := qualifyShortName(dnsQuery(t, "nas."), "", short); r != nil {
		t.Fatal("no MagicDNS suffix: rewritten")
	}
	if out, r := qualifyShortName([]byte{1, 2, 3}, suffix, short); r != nil || len(out) != 3 {
		t.Fatal("garbage: rewritten")
	}
}
