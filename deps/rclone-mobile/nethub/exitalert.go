package nethub

import (
	"errors"
	"strings"
	"sync"
)

// [FIX-261019-30] Consecutive-failure alerts for the outbound paths the user
// set up: each upstream proxy and the Tailscale node. When one of them fails
// AlertAfter times in a row the hub logs one "[Net][Alert]" line, and one
// "[Net][Recovered]" line on its next success. The app reads both from the
// log callback (no new C export) and shows a banner that opens the setting.
//
// Only failures that implicate the path itself count:
//   - proxy:     proxy-connect, proxy-tls, proxy-handshake. "proxy-target"
//     (the proxy works but cannot reach that host) does not.
//   - tailscale: tailnet (the dial through the node failed).
//
// Direct dials are never counted: they are not a setting to switch off.
//
// Line format, err last because it may contain spaces:
//
//	[Net][Alert] exit=proxy id=<upstream id> failures=<n> stage=<s> class=<c> name=<name> err=<msg>
//	[Net][Alert] exit=tailscale failures=<n> stage=tailnet class=<c> err=<msg>
//	[Net][Recovered] exit=proxy id=<upstream id>
//	[Net][Recovered] exit=tailscale
const AlertAfter = 3

type exitTracker struct {
	mu      sync.Mutex
	streak  map[string]int
	alerted map[string]bool
}

func newExitTracker() *exitTracker {
	return &exitTracker{streak: map[string]int{}, alerted: map[string]bool{}}
}

// exitKey is the alert subject for a decision, "" when it is never counted.
func exitKey(d Decision) string {
	switch d.Kind {
	case "proxy":
		if d.Upstream != nil {
			return "exit=proxy id=" + sanitizeField(d.Upstream.ID)
		}
	case "tailscale":
		return "exit=tailscale"
	}
	return ""
}

func countsAgainstExit(d Decision, stage string) bool {
	switch d.Kind {
	case "proxy":
		return stage == "proxy-connect" || stage == "proxy-tls" || stage == "proxy-handshake"
	case "tailscale":
		return stage == "tailnet"
	}
	return false
}

// recordExit is called once per dial with its outcome.
func (h *Hub) recordExit(d Decision, err error) {
	key := exitKey(d)
	if key == "" {
		return
	}
	t := h.exits
	if err == nil {
		t.mu.Lock()
		wasAlerted := t.alerted[key]
		delete(t.streak, key)
		delete(t.alerted, key)
		t.mu.Unlock()
		if wasAlerted {
			h.logf("[Net][Recovered] %s", key)
		}
		return
	}
	stage := Stage(err)
	if !countsAgainstExit(d, stage) {
		return
	}
	t.mu.Lock()
	t.streak[key]++
	n := t.streak[key]
	fire := n >= AlertAfter && !t.alerted[key]
	if fire {
		t.alerted[key] = true
	}
	t.mu.Unlock()
	if !fire {
		return
	}
	name := ""
	if d.Kind == "proxy" && d.Upstream != nil {
		name = " name=" + sanitizeField(d.Upstream.Name)
	}
	h.logf("[Net][Alert] %s failures=%d stage=%s class=%s%s err=%s",
		key, n, stage, Classify(err), name, oneLine(causeText(err)))
}

// resetExits forgets every streak, e.g. when the configuration changes.
func (h *Hub) resetExits() {
	h.exits.mu.Lock()
	h.exits.streak = map[string]int{}
	h.exits.alerted = map[string]bool{}
	h.exits.mu.Unlock()
}

// causeText is the underlying error: stage and class are separate fields.
func causeText(err error) string {
	var se *StageError
	if errors.As(err, &se) && se.Err != nil {
		return se.Err.Error()
	}
	return err.Error()
}

// sanitizeField keeps a value inside one space-separated key=value field.
func sanitizeField(s string) string {
	return strings.Map(func(r rune) rune {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == '=' {
			return '_'
		}
		return r
	}, s)
}

func oneLine(s string) string {
	s = strings.ReplaceAll(strings.ReplaceAll(s, "\r", " "), "\n", " ")
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return s
}
