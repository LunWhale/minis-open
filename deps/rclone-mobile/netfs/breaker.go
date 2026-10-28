package netfs

import (
	"sync"
	"time"
)

// State of a mount (design §5).
type State int

const (
	StateIdle State = iota
	StateConnecting
	StateOnline
	StateDegraded
	StateOffline
	StateHalfOpen
	StateAuthFailed
)

func (s State) String() string {
	return [...]string{"idle", "connecting", "online", "degraded", "offline", "half-open", "auth-failed"}[s]
}

// breaker is the per-mount state machine. All methods are safe for
// concurrent use.
//
//	Idle/Online/Degraded --failure--> Degraded --N in a row--> Offline
//	Offline --retryAt passed--> HalfOpen (exactly one request let through)
//	HalfOpen --success--> Online, --failure--> Offline (next backoff step)
//	any --auth failure--> AuthFailed (never retried on its own)
type breaker struct {
	mu        sync.Mutex
	now       func() time.Time
	threshold        int
	timeoutThreshold int
	backoff          []time.Duration

	state        State
	since        time.Time
	failures     int
	timeouts     int // consecutive timeouts within failures
	backoffIdx   int
	retryAt      time.Time
	probing      bool
	lastCause    Cause
	lastError    string
	// onTransition runs with the breaker locked: it gets a snapshot and must
	// not call back into the breaker.
	onTransition func(from, to State, snap breakerSnapshot)
}

func newBreaker(threshold int, backoff []time.Duration, now func() time.Time) *breaker {
	return &breaker{threshold: threshold, backoff: backoff, now: now, state: StateIdle, since: now()}
}

// admit says whether a network request may go out now. probe is true when
// this request is the single half-open probe; it must be reported back.
func (b *breaker) admit() (ok bool, probe bool, cause Cause) {
	b.mu.Lock()
	defer b.mu.Unlock()
	switch b.state {
	case StateAuthFailed:
		return false, false, CauseAuth
	case StateOffline:
		if b.probing || b.now().Before(b.retryAt) {
			return false, false, b.lastCause
		}
		b.probing = true
		b.setLocked(StateHalfOpen)
		return true, true, CauseNone
	case StateHalfOpen:
		// The probe is in flight; everyone else fails fast, no queueing.
		return false, false, b.lastCause
	case StateIdle:
		b.setLocked(StateConnecting)
	}
	return true, false, CauseNone
}

func (b *breaker) success(probe bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if probe {
		b.probing = false
	}
	b.failures = 0
	b.timeouts = 0
	b.backoffIdx = 0
	b.lastError = ""
	b.lastCause = CauseNone
	if b.state != StateOnline {
		b.setLocked(StateOnline)
	}
}

func (b *breaker) failure(probe bool, cause Cause, msg string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if probe {
		b.probing = false
	}
	b.lastCause = cause
	b.lastError = msg
	if cause == CauseAuth {
		b.setLocked(StateAuthFailed)
		return
	}
	b.failures++
	if cause == CauseTimeout {
		b.timeouts++
	} else {
		b.timeouts = 0
	}
	tooManyTimeouts := b.timeoutThreshold > 0 && b.timeouts >= b.timeoutThreshold
	if probe || b.failures >= b.threshold || tooManyTimeouts {
		d := b.backoff[min(b.backoffIdx, len(b.backoff)-1)]
		b.backoffIdx++
		b.retryAt = b.now().Add(d)
		b.setLocked(StateOffline)
		return
	}
	if b.state != StateDegraded {
		b.setLocked(StateDegraded)
	}
}

// release ends a probe that neither succeeded nor failed (e.g. not found).
func (b *breaker) release(probe bool) {
	if !probe {
		return
	}
	b.success(true)
}

// kick lets an offline mount probe right away (network came back, app came
// to the foreground).
func (b *breaker) kick() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.state == StateOffline {
		b.retryAt = b.now()
	}
}

// resetAuth leaves AuthFailed after the login was changed.
func (b *breaker) resetAuth() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.state == StateAuthFailed {
		b.failures = 0
		b.backoffIdx = 0
		b.setLocked(StateIdle)
	}
}

func (b *breaker) setLocked(to State) {
	from := b.state
	b.state = to
	b.since = b.now()
	if b.onTransition != nil && from != to {
		b.onTransition(from, to, b.snapshotLocked())
	}
}

type breakerSnapshot struct {
	State     State
	Since     time.Time
	Failures  int
	RetryAt   time.Time
	LastCause Cause
	LastError string
}

func (b *breaker) snapshot() breakerSnapshot {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.snapshotLocked()
}

func (b *breaker) snapshotLocked() breakerSnapshot {
	return breakerSnapshot{b.state, b.since, b.failures, b.retryAt, b.lastCause, b.lastError}
}
