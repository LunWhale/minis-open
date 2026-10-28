package nethub

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strings"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// MARK: - DNS of the iSH shell (deps/ish fs/xnet.h dns_intercept)
//
// iSH sends what a guest sends to port 53 of its own resolver (the
// nameserver in its /etc/resolv.conf, e.g. a system resolver like
// 198.18.0.4) here, as a "~dns" association (UDP) or a "~dns" CONNECT
// (TCP), instead of to the resolver. Each query is answered by:
//
//   - the Tailscale node's own resolver (what 100.100.100.100 answers), for
//     MagicDNS names and tailnet short names while the node is up - the
//     shell can then resolve them, which it could not before; and for every
//     name when an exit node is in use and Config.ExitNodeDNS is on, so DNS
//     leaves where the traffic leaves;
//   - otherwise the guest's resolver itself, directly, exactly as without
//     the hub (through the tailnet only if that resolver is a tailnet
//     address). This is the default with an exit node too: the device's own
//     resolver may only work on the device (a VPN app's 198.18.0.x, a
//     company's split DNS), and going through the exit node changes answers
//     and latency. The cost is that those queries leave from the device's
//     own network, not the exit node's.
//
// Queries are passed on as they are (ID, flags, EDNS), and answers come back
// as they are; nothing is cached here.

// DNSQuerier is optionally implemented by a Tailnet: answer a raw DNS query
// with the node's resolver. tcp tells it how the client asked (an answer too
// big for UDP is then truncated, and the client retries over TCP).
type DNSQuerier interface {
	QueryDNS(ctx context.Context, query []byte, tcp bool) ([]byte, error)
}

const dnsTimeout = 5 * time.Second

// dnsQuestion returns the first question's name (lower case, without the
// final dot) and type, or "" for something that is not a query.
func dnsQuestion(msg []byte) (string, dnsmessage.Type) {
	var p dnsmessage.Parser
	h, err := p.Start(msg)
	if err != nil || h.Response {
		return "", 0
	}
	q, err := p.Question()
	if err != nil {
		return "", 0
	}
	return strings.ToLower(strings.TrimSuffix(q.Name.String(), ".")), q.Type
}

// dnsVia decides who answers a query for name: "tailnet" (the node's
// resolver) or "resolver" (the guest's own), and the rule that decided.
func (h *Hub) dnsVia(name string) (via, rule string) {
	if !h.tailscaleUp() {
		return "resolver", "node-down"
	}
	if _, ok := h.ts.(DNSQuerier); !ok {
		return "resolver", "no-node-resolver"
	}
	if name != "" && h.ts.IsTailnetName(name) {
		return "tailnet", "tailnet-name"
	}
	h.mu.RLock()
	exitDNS := h.cfg.ExitNodeDNS
	h.mu.RUnlock()
	if exitDNS && h.ts.ExitNodeActive() {
		return "tailnet", "exit-node-dns"
	}
	return "resolver", "route"
}

// answerDNS answers one query. resolver is the guest's resolver
// ("ip:port"); upstream, if non-nil, is a TCP connection to it that can be
// reused (DNS over TCP), opened on demand.
func (h *Hub) answerDNS(id, tag, resolver string, query []byte, tcp bool, upstream *net.Conn) ([]byte, error) {
	h.udp.dnsQueries.Add(1)
	name, qtype := dnsQuestion(query)
	via, rule := h.dnsVia(name)
	ctx, cancel := context.WithTimeout(context.Background(), dnsTimeout)
	defer cancel()
	t0 := time.Now()
	var answer []byte
	var err error
	if via == "tailnet" {
		h.udp.dnsTailnet.Add(1)
		answer, err = h.ts.(DNSQuerier).QueryDNS(ctx, query, tcp)
		err = stageErr("dns-tailnet", err)
	} else if tcp {
		answer, err = h.exchangeTCP(ctx, resolver, query, upstream)
	} else {
		answer, err = h.exchangeUDP(ctx, resolver, query)
	}
	ms := time.Since(t0).Milliseconds()
	if err != nil {
		h.udp.dnsFailures.Add(1)
		if h.failLog.allow("dns|" + via + "|" + Classify(err)) {
			h.logf("[Net][DNS] %s FAIL name=%s type=%s via=%s rule=%s resolver=%s class=%s after %dms tag=%s: %v",
				id, orNone(name), qtype, via, rule, resolver, Classify(err), ms, tag, err)
		}
		return nil, err
	}
	if h.okLog.allow("dns|" + via + "|" + name) {
		h.logf("[Net][DNS] %s name=%s type=%s via=%s rule=%s rcode=%s in %dms", id, orNone(name), qtype, via, rule, dnsRcode(answer), ms)
	}
	return answer, nil
}

func dnsRcode(msg []byte) string {
	var p dnsmessage.Parser
	h, err := p.Start(msg)
	if err != nil {
		return "?"
	}
	return strings.TrimPrefix(h.RCode.String(), "RCode")
}

// resolverDial reaches the guest's resolver: through the tailnet if it is a
// tailnet address, directly otherwise - never through an exit node (that
// resolver is the device's, it may not exist anywhere else).
func (h *Hub) resolverDial(ctx context.Context, network, resolver string) (net.Conn, error) {
	if h.tailscaleUp() && h.isTailnetDest(hostOf(resolver)) {
		c, err := h.ts.Dial(ctx, network, resolver)
		return c, stageErr("dns-tailnet", err)
	}
	c, err := h.dialDirect(ctx, network, resolver)
	return c, stageErr("dns-direct", err)
}

func (h *Hub) exchangeUDP(ctx context.Context, resolver string, query []byte) ([]byte, error) {
	c, err := h.resolverDial(ctx, "udp", resolver)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	if dl, ok := ctx.Deadline(); ok {
		c.SetDeadline(dl)
	}
	if _, err := c.Write(query); err != nil {
		return nil, stageErr("dns-direct", err)
	}
	buf := make([]byte, udpMaxDatagram)
	for {
		n, err := c.Read(buf)
		if err != nil {
			return nil, stageErr("dns-direct", err)
		}
		// The answer to this query (same ID); anything else is stale.
		if n >= 2 && len(query) >= 2 && buf[0] == query[0] && buf[1] == query[1] {
			return append([]byte(nil), buf[:n]...), nil
		}
	}
}

func (h *Hub) exchangeTCP(ctx context.Context, resolver string, query []byte, upstream *net.Conn) ([]byte, error) {
	for attempt := 0; attempt < 2; attempt++ {
		if *upstream == nil {
			c, err := h.resolverDial(ctx, "tcp", resolver)
			if err != nil {
				return nil, err
			}
			*upstream = c
		}
		c := *upstream
		if dl, ok := ctx.Deadline(); ok {
			c.SetDeadline(dl)
		}
		answer, err := dnsTCPRoundTrip(c, query)
		if err == nil {
			return answer, nil
		}
		// The resolver may have closed a kept connection: one new try.
		c.Close()
		*upstream = nil
		if attempt == 1 || ctx.Err() != nil {
			return nil, stageErr("dns-direct", err)
		}
	}
	return nil, errors.New("unreachable")
}

func dnsTCPRoundTrip(c net.Conn, query []byte) ([]byte, error) {
	frame := make([]byte, 2+len(query))
	binary.BigEndian.PutUint16(frame, uint16(len(query)))
	copy(frame[2:], query)
	if _, err := c.Write(frame); err != nil {
		return nil, err
	}
	return readDNSFrame(c)
}

func readDNSFrame(r io.Reader) ([]byte, error) {
	var l [2]byte
	if _, err := io.ReadFull(r, l[:]); err != nil {
		return nil, err
	}
	msg := make([]byte, binary.BigEndian.Uint16(l[:]))
	if _, err := io.ReadFull(r, msg); err != nil {
		return nil, err
	}
	return msg, nil
}

// answerUDPDNS answers one datagram of a "~dns" association and sends the
// answer back as coming from the resolver. A query that gets no answer gets
// none here either: the client retries or times out, as it would have.
func (h *Hub) answerUDPDNS(a *udpAssoc, resolver string, hdr, query []byte) {
	var none *net.Conn
	answer, err := h.answerDNS(a.id, a.tag, resolver, query, false, none)
	if err != nil {
		return
	}
	a.mu.Lock()
	a.sent++
	a.mu.Unlock()
	a.toClient(append(hdr, answer...))
}

// serveDNSTCP serves a "~dns" CONNECT to the guest's resolver: DNS over TCP,
// one query after the other, each answered as above.
func (h *Hub) serveDNSTCP(c net.Conn, id, tag, resolver string) {
	if err := writeReply(c, repSuccess); err != nil {
		return
	}
	h.dnsOverTCP(c, id, tag, resolver)
}

// dnsOverTCP answers DNS-over-TCP frames on c until it closes - for a
// "~dns" CONNECT above, and for proot's TCP connections to the shell's
// resolver (xmap.go, a destination file marked "dns").
func (h *Hub) dnsOverTCP(c net.Conn, id, tag, resolver string) {
	h.active.Add(1)
	defer h.active.Add(-1)
	var upstream net.Conn
	defer func() {
		if upstream != nil {
			upstream.Close()
		}
	}()
	for {
		c.SetReadDeadline(time.Now().Add(2 * time.Minute))
		query, err := readDNSFrame(c)
		if err != nil {
			return
		}
		answer, err := h.answerDNS(id, tag, resolver, query, true, &upstream)
		if err != nil {
			answer = dnsServFail(query)
			if answer == nil {
				return
			}
		}
		frame := make([]byte, 2+len(answer))
		binary.BigEndian.PutUint16(frame, uint16(len(answer)))
		copy(frame[2:], answer)
		if _, err := c.Write(frame); err != nil {
			return
		}
	}
}

// dnsServFail answers query with SERVFAIL (same ID and question), so a TCP
// client is told at once instead of waiting on a connection that cannot
// answer. nil if query does not parse.
func dnsServFail(query []byte) []byte {
	var p dnsmessage.Parser
	hdr, err := p.Start(query)
	if err != nil {
		return nil
	}
	q, err := p.Question()
	if err != nil {
		return nil
	}
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: hdr.ID, Response: true, OpCode: hdr.OpCode,
		RecursionDesired: hdr.RecursionDesired, RecursionAvailable: true, RCode: dnsmessage.RCodeServerFailure})
	b.StartQuestions()
	b.Question(q)
	out, err := b.Finish()
	if err != nil {
		return nil
	}
	return out
}
