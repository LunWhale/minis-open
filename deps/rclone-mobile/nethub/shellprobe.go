package nethub

import (
	"errors"
	"io"
	"net"
	"strings"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// MARK: - Diagnose: the iSH shell's UDP and DNS, exercised from the app
//
// The kernel's own counters say what the shell did; these say whether the
// path works right now, without a guest program: a UDP association on the
// entry with one datagram to a loopback echo (entry, relay and return path),
// and DNS queries answered exactly as the shell's intercepted DNS is.

// UDPSelfTest associates with the entry as a client would, sends one
// datagram to a throwaway loopback echo and waits for it to come back.
func (h *Hub) UDPSelfTest(timeout time.Duration) (time.Duration, error) {
	h.mu.RLock()
	ln, pass := h.ln, h.password
	h.mu.RUnlock()
	if ln == nil || h.dead.Load() {
		return 0, &StageError{Stage: "entry", Class: ClassClosed, Err: errors.New("local entry is not listening")}
	}
	fail := func(stage string, err error) (time.Duration, error) {
		return 0, &StageError{Stage: stage, Class: Classify(err), Err: err}
	}
	echo, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		return fail("udp-echo", err)
	}
	defer echo.Close()
	go func() {
		buf := make([]byte, 512)
		echo.SetReadDeadline(time.Now().Add(timeout))
		n, from, err := echo.ReadFromUDP(buf)
		if err == nil {
			echo.WriteToUDP(buf[:n], from)
		}
	}()
	client, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		return fail("udp-client", err)
	}
	defer client.Close()
	t0 := time.Now()
	c, err := net.DialTimeout("tcp", ln.Addr().String(), timeout)
	if err != nil {
		return fail("entry", err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(timeout))
	user := "diagnose"
	auth := append([]byte{1, byte(len(user))}, user...)
	auth = append(append(auth, byte(len(pass))), pass...)
	var r2 [2]byte
	if _, err := c.Write([]byte{5, 1, 2}); err != nil {
		return fail("entry", err)
	}
	if _, err := io.ReadFull(c, r2[:]); err != nil {
		return fail("entry", err)
	}
	if _, err := c.Write(auth); err != nil {
		return fail("entry", err)
	}
	if _, err := io.ReadFull(c, r2[:]); err != nil || r2[1] != 0 {
		return fail("entry", errors.New("authentication failed"))
	}
	p := client.LocalAddr().(*net.UDPAddr).Port
	if _, err := c.Write([]byte{5, cmdUDPAssociate, 0, 1, 127, 0, 0, 1, byte(p >> 8), byte(p)}); err != nil {
		return fail("udp-associate", err)
	}
	var rep [10]byte
	if _, err := io.ReadFull(c, rep[:]); err != nil {
		return fail("udp-associate", err)
	}
	if rep[1] != 0 {
		return fail("udp-associate", errors.New("the entry refused UDP ASSOCIATE"))
	}
	relay := &net.UDPAddr{IP: net.IP(rep[4:8]), Port: int(rep[8])<<8 | int(rep[9])}
	ea := echo.LocalAddr().(*net.UDPAddr)
	if _, err := client.WriteToUDP(append(udpHeader("127.0.0.1", ea.Port), "probe"...), relay); err != nil {
		return fail("udp-relay", err)
	}
	buf := make([]byte, 512)
	client.SetReadDeadline(time.Now().Add(timeout))
	n, _, err := client.ReadFromUDP(buf)
	if err != nil {
		return fail("udp-relay", err)
	}
	if _, _, payload, err := parseUDPHeader(buf[:n]); err != nil || string(payload) != "probe" {
		return fail("udp-relay", errors.New("the relay returned something else"))
	}
	return time.Since(t0), nil
}

// DNSProbeResult is one name looked up by DNSProbe.
type DNSProbeResult struct {
	Name    string `json:"name"`
	Via     string `json:"via"`  // tailnet (the node's resolver) or resolver (the shell's own)
	Rule    string `json:"rule"` // why: tailnet-name, exit-node-dns, route, node-down
	Rcode   string `json:"rcode,omitempty"`
	Answers int    `json:"answers"`
	Ms      int64  `json:"ms"`
	Error   string `json:"error,omitempty"`
}

// DNSProbe looks each name up (type A) as the shell's intercepted DNS would
// be answered, with resolver ("ip:53") as the shell's nameserver.
func (h *Hub) DNSProbe(resolver string, names []string) []DNSProbeResult {
	out := make([]DNSProbeResult, 0, len(names))
	for i, name := range names {
		name = strings.TrimSuffix(strings.TrimSpace(name), ".")
		r := DNSProbeResult{Name: name}
		r.Via, r.Rule = h.dnsVia(strings.ToLower(name))
		b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: uint16(0xd000 + i), RecursionDesired: true})
		b.StartQuestions()
		n, err := dnsmessage.NewName(name + ".")
		if err == nil {
			err = b.Question(dnsmessage.Question{Name: n, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET})
		}
		var q []byte
		if err == nil {
			q, err = b.Finish()
		}
		if err != nil {
			r.Error = err.Error()
			out = append(out, r)
			continue
		}
		t0 := time.Now()
		var none *net.Conn
		answer, err := h.answerDNS("probe", "diagnose", resolver, q, false, none)
		r.Ms = time.Since(t0).Milliseconds()
		if err != nil {
			r.Error = "stage=" + Stage(err) + " class=" + Classify(err) + ": " + err.Error()
			out = append(out, r)
			continue
		}
		r.Rcode = dnsRcode(answer)
		var p dnsmessage.Parser
		if _, err := p.Start(answer); err == nil {
			p.SkipAllQuestions()
			if all, err := p.AllAnswers(); err == nil {
				r.Answers = len(all)
			}
		}
		out = append(out, r)
	}
	return out
}
