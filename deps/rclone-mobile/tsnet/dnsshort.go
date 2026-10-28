package tsnet

import (
	"strings"

	"golang.org/x/net/dns/dnsmessage"
)

// qualifyShortName rewrites a query for a bare tailnet short name ("nas",
// a peer's or this node's first DNS label) to its MagicDNS name
// ("nas.tailXXXX.ts.net"). The node's resolver only answers full MagicDNS
// names: a bare name goes on to the upstream resolvers - with an exit node,
// the exit node's own, which may answer it from its /etc/hosts (127.0.1.1
// for its own host name) - where a tailnet name must never go. restore puts
// the asked name back into the answer's question and records, so the stub
// resolver sees an answer to what it asked. Other queries: query as it is,
// restore nil.
func qualifyShortName(query []byte, suffix string, short map[string]bool) ([]byte, func([]byte) []byte) {
	if suffix == "" {
		return query, nil
	}
	var m dnsmessage.Message
	if err := m.Unpack(query); err != nil || m.Response || len(m.Questions) != 1 {
		return query, nil
	}
	asked := m.Questions[0].Name
	label := strings.ToLower(strings.TrimSuffix(asked.String(), "."))
	if label == "" || strings.Contains(label, ".") || !short[label] {
		return query, nil
	}
	full, err := dnsmessage.NewName(label + "." + strings.Trim(suffix, ".") + ".")
	if err != nil {
		return query, nil
	}
	m.Questions[0].Name = full
	q, err := m.Pack()
	if err != nil {
		return query, nil
	}
	restore := func(answer []byte) []byte {
		var a dnsmessage.Message
		if err := a.Unpack(answer); err != nil {
			return answer
		}
		for i := range a.Questions {
			if strings.EqualFold(a.Questions[i].Name.String(), full.String()) {
				a.Questions[i].Name = asked
			}
		}
		for _, rrs := range [][]dnsmessage.Resource{a.Answers, a.Authorities, a.Additionals} {
			for i := range rrs {
				if strings.EqualFold(rrs[i].Header.Name.String(), full.String()) {
					rrs[i].Header.Name = asked
				}
			}
		}
		out, err := a.Pack()
		if err != nil {
			return answer
		}
		return out
	}
	return q, restore
}
