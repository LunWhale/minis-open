package netfs

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/config/configmap"
	"github.com/rclone/rclone/fs/config/obscure"
)

// Config for one mount. Durations of zero take the design's initial values
// (design §6), via withDefaults.
type Config struct {
	Name   string            // mount name, /var/minis/mounts/<Name>
	Type   string            // rclone backend: webdav, sftp, smb, ftp, s3
	Params map[string]string // backend options; passwords in CLEAR text
	Root   string            // path inside the remote
	// TrustedCertSHA256: a self-signed certificate the user trusted by its
	// fingerprint (tls.go). Empty: only certificates the system trusts.
	TrustedCertSHA256 string

	ConnectTimeout time.Duration // per-mount rclone ConnectTimeout
	IOTimeout      time.Duration // per-mount rclone Timeout (response header / idle)
	MetaTimeout    time.Duration // total for one stat
	// ListTimeout is the total for one directory listing. [T-netmount-list-timeout]
	// A listing is one request whose size grows with the folder (20k photos
	// over a VPN take ~10 s): with a stat's 8 s it timed out every time, and
	// two timeouts in a row took the whole disk offline. It gets a block
	// read's deadline instead. A listing timeout still counts toward offline,
	// so a server that accepts and never answers is still detected.
	ListTimeout time.Duration
	ReadTimeout    time.Duration // total for one block
	MaxConcurrent  int
	QueueWait      time.Duration

	DirCacheTTL time.Duration // fresh listing
	StaleMax    time.Duration // how long an expired listing may stand in on failure
	NegativeTTL time.Duration

	FailThreshold    int           // consecutive failures before offline
	TimeoutThreshold int           // consecutive TIMEOUTS before offline (fewer: each one cost a full deadline)
	ProbeTimeout     time.Duration // deadline of the single half-open probe
	Backoff          []time.Duration

	BlockSize  int64
	CacheDir   string // block cache; may be wiped by the OS at any time
	CacheLimit int64  // bytes

	RatePerSec     float64 // metadata requests per second
	RateBurst      int
	CallBudgetOps  int           // metadata requests per budget key
	CallBudgetTime time.Duration // wall time per budget key
	// BudgetIdleGap: a key with no request for this long starts a new
	// window. Commands are bursts; this ends one without the app having to
	// say so (it still can, with ResetBudget at each tool call).
	BudgetIdleGap time.Duration

	// OnTransition is called on every state change (dmesg line, /proc
	// snapshot). It runs on the goroutine that caused the change, with no
	// netfs lock held.
	OnTransition func(name string, from, to State, st Status)
	// Now is for tests.
	Now func() time.Time
}

func (c Config) withDefaults() Config {
	d := func(v *time.Duration, def time.Duration) {
		if *v == 0 {
			*v = def
		}
	}
	d(&c.ConnectTimeout, 10*time.Second)
	d(&c.IOTimeout, 20*time.Second)
	// Phase-1 tuning (ADDENDUM_7 P1-1): a lookup walks several uncached path
	// components, each paying this deadline, so it stays short.
	d(&c.MetaTimeout, 8*time.Second)
	d(&c.ListTimeout, 30*time.Second)
	d(&c.ProbeTimeout, 5*time.Second)
	d(&c.ReadTimeout, 30*time.Second)
	d(&c.QueueWait, 5*time.Second)
	d(&c.DirCacheTTL, 30*time.Second)
	d(&c.StaleMax, 10*time.Minute)
	d(&c.NegativeTTL, 5*time.Second)
	d(&c.CallBudgetTime, 60*time.Second)
	d(&c.BudgetIdleGap, 3*time.Second)
	if c.MaxConcurrent == 0 {
		c.MaxConcurrent = 4
	}
	if c.FailThreshold == 0 {
		c.FailThreshold = 3
	}
	if c.TimeoutThreshold == 0 {
		c.TimeoutThreshold = 2
	}
	if len(c.Backoff) == 0 {
		c.Backoff = []time.Duration{5 * time.Second, 15 * time.Second, 45 * time.Second, 2 * time.Minute, 5 * time.Minute}
	}
	if c.BlockSize == 0 {
		c.BlockSize = 1 << 20
	}
	if c.CacheLimit == 0 {
		c.CacheLimit = 512 << 20
	}
	// ADDENDUM_7 P1-2: 20/s made `find` over 300 LAN directories take 13 s;
	// the 2000-request budget is what guards against runaway recursion.
	if c.RatePerSec == 0 {
		c.RatePerSec = 50
	}
	if c.RateBurst == 0 {
		c.RateBurst = 100
	}
	if c.CallBudgetOps == 0 {
		c.CallBudgetOps = 2000
	}
	if c.Now == nil {
		c.Now = time.Now
	}
	return c
}

// Entry is one file or directory.
type Entry struct {
	Name    string
	IsDir   bool
	Size    int64
	ModTime time.Time
}

// Status is what /proc/fs/netfs/<name> shows.
type Status struct {
	Name                string
	Type                string
	Server              string
	State               State
	Since               time.Time
	LastCause           Cause
	LastError           string
	RetryAt             time.Time
	ConsecutiveFailures int
	CacheBytes          int64
	Ops                 OpCounters
	InFlight            int
}

// OpCounters count network requests (cache hits are not counted).
type OpCounters struct {
	Stat, ReadDir, Read, Timeouts, FastFails, StaleServed int64
}

// Mount is one remote served read-only.
type Mount struct {
	cfg     Config
	baseCtx context.Context
	pin     *certPin // nil unless TrustedCertSHA256 is set
	br      *breaker

	fsMu sync.Mutex
	f    fs.Fs

	sem      chan struct{}
	inFlight atomic.Int64

	metaMu sync.Mutex
	dirs   map[string]*dirEntry // listings by dir path ("" = root)
	neg    map[string]time.Time // known-missing paths

	blocks *blockCache

	rate *tokenBucket

	budgetMu sync.Mutex
	budgets  map[uint64]*budget

	ops OpCounters // atomic adds

	seqMu   sync.Mutex
	lastBlk map[string]int64 // last block read per file, for read-ahead
}

type dirEntry struct {
	at      time.Time
	entries map[string]Entry
}

type budget struct {
	start time.Time
	last  time.Time
	ops   int
}

// NewMount prepares a mount. It does not touch the network: the backend is
// created by the first operation, so mounting never depends on the server
// being up (design §5.1 principle 5).
func NewMount(cfg Config) (*Mount, error) {
	cfg = cfg.withDefaults()
	if cfg.Name == "" || cfg.Type == "" {
		return nil, fmt.Errorf("netfs: name and type are required")
	}
	if _, err := fs.Find(cfg.Type); err != nil {
		return nil, fmt.Errorf("netfs: unknown backend %q", cfg.Type)
	}
	// Per-mount rclone config: these timeouts must not change the global
	// ones the backup feature relies on (RcloneBridge.applyGlobalOptions).
	ctx, ci := fs.AddConfig(context.Background())
	ci.ConnectTimeout = fs.Duration(cfg.ConnectTimeout)
	ci.Timeout = fs.Duration(cfg.IOTimeout)
	ci.LowLevelRetries = 1
	ci.Retries = 1
	var pin *certPin
	if want := NormalizeFingerprint(cfg.TrustedCertSHA256); want != "" {
		// Chain checks off for THIS mount only; the fingerprint check in
		// tls.go replaces them on every request.
		ci.InsecureSkipVerify = true
		pin = &certPin{want: want}
		ctx = pin.context(ctx)
	}
	m := &Mount{
		pin:     pin,
		cfg:     cfg,
		baseCtx: ctx,
		sem:     make(chan struct{}, cfg.MaxConcurrent),
		dirs:    map[string]*dirEntry{},
		neg:     map[string]time.Time{},
		rate:    newTokenBucket(cfg.RatePerSec, cfg.RateBurst, cfg.Now),
		budgets: map[uint64]*budget{},
		lastBlk: map[string]int64{},
	}
	if cfg.CacheDir != "" {
		m.blocks = newBlockCache(cfg.CacheDir, cfg.CacheLimit)
	}
	m.br = newBreaker(cfg.FailThreshold, cfg.Backoff, cfg.Now)
	m.br.timeoutThreshold = cfg.TimeoutThreshold
	m.br.onTransition = func(from, to State, snap breakerSnapshot) {
		if cfg.OnTransition == nil {
			return
		}
		st := m.statusFrom(snap)
		// Not under the breaker lock any more by the time the hook runs.
		go cfg.OnTransition(cfg.Name, from, to, st)
	}
	return m, nil
}

// Name of the mount.
func (m *Mount) Name() string { return m.cfg.Name }

// Kick lets an offline mount probe now (network up, app foreground).
func (m *Mount) Kick() { m.br.kick() }

// ResetAuth leaves AuthFailed after the login changed.
func (m *Mount) ResetAuth() { m.br.resetAuth() }

// ResetBudget starts a new tool call for this key (design §6).
func (m *Mount) ResetBudget(key uint64) {
	m.budgetMu.Lock()
	delete(m.budgets, key)
	m.budgetMu.Unlock()
}

// Status snapshot.
func (m *Mount) Status() Status { return m.statusFrom(m.br.snapshot()) }

func (m *Mount) statusFrom(s breakerSnapshot) Status {
	st := Status{
		Name: m.cfg.Name, Type: m.cfg.Type, Server: serverOf(m.cfg),
		State: s.State, Since: s.Since, LastCause: s.LastCause, LastError: s.LastError,
		RetryAt: s.RetryAt, ConsecutiveFailures: s.Failures,
		InFlight: int(m.inFlight.Load()),
		Ops: OpCounters{
			Stat: atomic.LoadInt64(&m.ops.Stat), ReadDir: atomic.LoadInt64(&m.ops.ReadDir),
			Read: atomic.LoadInt64(&m.ops.Read), Timeouts: atomic.LoadInt64(&m.ops.Timeouts),
			FastFails: atomic.LoadInt64(&m.ops.FastFails), StaleServed: atomic.LoadInt64(&m.ops.StaleServed),
		},
	}
	if m.blocks != nil {
		st.CacheBytes = m.blocks.size()
	}
	return st
}

func serverOf(c Config) string {
	for _, k := range []string{"url", "host", "endpoint"} {
		if v := c.Params[k]; v != "" {
			return v
		}
	}
	return ""
}

// clean turns a guest path ("", "/a/b", "a/b/") into rclone's form ("a/b").
func clean(p string) string {
	p = path.Clean("/" + p)
	return strings.TrimPrefix(p, "/")
}

// MARK: - Backend

func (m *Mount) backend(ctx context.Context) (fs.Fs, error) {
	m.fsMu.Lock()
	defer m.fsMu.Unlock()
	if m.f != nil {
		return m.f, nil
	}
	ri, err := fs.Find(m.cfg.Type)
	if err != nil {
		return nil, err
	}
	// Passwords reach rclone obscured, as its backends reveal them on use.
	// Built in memory: nothing goes through rclone's config file (design §2-⑤).
	params := configmap.Simple{}
	for k, v := range m.cfg.Params {
		params[k] = v
	}
	for _, opt := range ri.Options {
		if opt.IsPassword {
			if v, ok := params[opt.Name]; ok {
				params[opt.Name] = obscure.MustObscure(v)
			}
		}
	}
	f, err := ri.NewFs(ctx, m.cfg.Name, m.cfg.Root, params)
	if err != nil && err != fs.ErrorIsFile {
		return nil, err
	}
	m.f = f
	return f, nil
}

// MARK: - The bounded runner

type opKind int

const (
	opMeta opKind = iota
	opRead
	opList // a directory listing: metadata budget and rate, ListTimeout
)

// run executes one network operation within every bound the design sets:
// breaker → budget → rate → concurrency gate → deadline. It returns when fn
// finishes or the deadline passes; a late fn keeps its gate slot until it
// returns, which is what bounds the goroutines of a stuck backend.
//
// cancel (may be nil) is closed when the guest thread waiting on this call got
// a fatal signal: the caller returns EINTR at once. That is not a failure of
// the mount, so the breaker is not told.
func (m *Mount) run(kind opKind, key uint64, cancel <-chan struct{}, fn func(ctx context.Context, f fs.Fs) error) *Error {
	ok, probe, cause := m.br.admit()
	if !ok {
		atomic.AddInt64(&m.ops.FastFails, 1)
		if cause == CauseNone {
			cause = CauseOther
		}
		return newErr(cause.Errno(), cause, "mount is "+m.br.snapshot().State.String())
	}
	if kind == opMeta || kind == opList {
		if e := m.chargeBudget(key); e != nil {
			m.br.release(probe)
			return e
		}
		if !m.rate.wait(m.cfg.QueueWait) {
			m.br.release(probe)
			atomic.AddInt64(&m.ops.Timeouts, 1)
			return newErr(ETIMEDOUT, CauseTimeout, "metadata rate limit")
		}
	}
	timeout := m.cfg.MetaTimeout
	switch kind {
	case opRead:
		timeout = m.cfg.ReadTimeout
	case opList:
		timeout = m.cfg.ListTimeout
	}
	if probe && m.cfg.ProbeTimeout < timeout {
		// A probe only answers "is it back?"; a hung server must not hold
		// every caller that lands on a retry window for a full deadline.
		timeout = m.cfg.ProbeTimeout
	}
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	queue := time.NewTimer(m.cfg.QueueWait)
	defer queue.Stop()
	select {
	case m.sem <- struct{}{}:
	case <-queue.C:
		m.br.release(probe)
		atomic.AddInt64(&m.ops.Timeouts, 1)
		return newErr(ETIMEDOUT, CauseTimeout, "too many requests in flight")
	case <-cancel:
		m.br.release(probe)
		return newErr(EINTR, CauseNone, "cancelled")
	}
	ctx, stop := context.WithTimeout(m.baseCtx, timeout)
	done := make(chan error, 1)
	m.inFlight.Add(1)
	go func() {
		defer func() { <-m.sem; m.inFlight.Add(-1); stop() }()
		f, err := m.backend(ctx)
		if err == nil {
			err = fn(ctx, f)
		}
		done <- err
	}()
	var err error
	select {
	case err = <-done:
	case <-deadline.C:
		err = context.DeadlineExceeded
	case <-cancel:
		// The goroutine finishes on its own (its deadline still applies) and
		// releases its gate slot then; a half-open probe stays the probe.
		go func() {
			r := <-done
			if r == nil {
				m.br.success(probe)
			} else if c, _ := m.causeOf(r); c == CauseNotFound || c == CauseForbidden {
				m.br.release(probe)
			} else {
				m.br.failure(probe, c, r.Error())
			}
		}()
		return newErr(EINTR, CauseNone, "cancelled")
	}
	if err == nil {
		m.br.success(probe)
		return nil
	}
	c, got := m.causeOf(err)
	msg := err.Error()
	if got != "" {
		msg = "certificate changed: the server presented sha256 " + got + ", not the trusted one"
	}
	switch c {
	case CauseNotFound:
		m.br.release(probe)
		return newErr(ENOENT, c, msg)
	case CauseForbidden:
		// The server answered: the mount is fine, this path is not readable.
		m.br.release(probe)
		return newErr(EACCES, c, msg)
	case CauseTimeout:
		atomic.AddInt64(&m.ops.Timeouts, 1)
	}
	m.br.failure(probe, c, msg)
	return newErr(c.Errno(), c, msg)
}

// causeOf classifies a backend error, naming certificate problems: a pinned
// fingerprint that did not match shows up to the backend only as a closed
// connection.
// The second result is the fingerprint the server presented on a mismatch.
func (m *Mount) causeOf(err error) (Cause, string) {
	if got := m.pin.takeMismatch(); got != "" {
		return CauseCert, got
	}
	if isCertError(err) {
		return CauseCert, ""
	}
	return classify(err), ""
}

func (m *Mount) chargeBudget(key uint64) *Error {
	if key == 0 {
		return nil
	}
	m.budgetMu.Lock()
	defer m.budgetMu.Unlock()
	now := m.cfg.Now()
	b := m.budgets[key]
	if b == nil || now.Sub(b.last) >= m.cfg.BudgetIdleGap {
		b = &budget{start: now}
		m.budgets[key] = b
	}
	b.last = now
	if b.ops >= m.cfg.CallBudgetOps || now.Sub(b.start) >= m.cfg.CallBudgetTime {
		return newErr(ETIMEDOUT, CauseTimeout, "network budget for this command used up")
	}
	b.ops++
	return nil
}

// MARK: - Metadata

// ReadDir lists a directory. A listing younger than DirCacheTTL is served from
// memory; an older one is refreshed, and on failure served stale for up to
// StaleMax (design §5.5).
func (m *Mount) ReadDir(dir string, key uint64, cancel <-chan struct{}) ([]Entry, *Error) {
	dir = clean(dir)
	now := m.cfg.Now()
	m.metaMu.Lock()
	cached := m.dirs[dir]
	m.metaMu.Unlock()
	if cached != nil && now.Sub(cached.at) < m.cfg.DirCacheTTL {
		return sortedEntries(cached.entries), nil
	}
	var listing fs.DirEntries
	e := m.run(opList, key, cancel, func(ctx context.Context, f fs.Fs) error {
		atomic.AddInt64(&m.ops.ReadDir, 1)
		var err error
		listing, err = f.List(ctx, dir)
		return err
	})
	if e != nil {
		if e.Errno == ENOENT {
			m.forgetDir(dir)
			return nil, e
		}
		if e.Errno == EINTR {
			return nil, e
		}
		if cached != nil && now.Sub(cached.at) < m.cfg.StaleMax {
			atomic.AddInt64(&m.ops.StaleServed, 1)
			return sortedEntries(cached.entries), nil
		}
		return nil, e
	}
	entries := map[string]Entry{}
	for _, it := range listing {
		name := path.Base(it.Remote())
		ent := Entry{Name: name, ModTime: it.ModTime(m.baseCtx), Size: it.Size()}
		if _, isDir := it.(fs.Directory); isDir {
			ent.IsDir = true
			ent.Size = 0
		}
		entries[name] = ent
	}
	m.metaMu.Lock()
	m.dirs[dir] = &dirEntry{at: m.cfg.Now(), entries: entries}
	m.metaMu.Unlock()
	return sortedEntries(entries), nil
}

func (m *Mount) forgetDir(dir string) {
	m.metaMu.Lock()
	delete(m.dirs, dir)
	m.metaMu.Unlock()
}

func sortedEntries(in map[string]Entry) []Entry {
	out := make([]Entry, 0, len(in))
	for _, e := range in {
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// Stat looks a path up through its parent's listing, so `ls -l` on a
// directory costs one listing, not one request per entry. The mount root is
// answered locally: listing /var/minis/mounts never touches the network.
func (m *Mount) Stat(p string, key uint64, cancel <-chan struct{}) (Entry, *Error) {
	p = clean(p)
	if p == "" {
		return Entry{Name: "", IsDir: true}, nil
	}
	now := m.cfg.Now()
	m.metaMu.Lock()
	if t, ok := m.neg[p]; ok && now.Sub(t) < m.cfg.NegativeTTL {
		m.metaMu.Unlock()
		return Entry{}, newErr(ENOENT, CauseNotFound, "not found (cached)")
	}
	m.metaMu.Unlock()
	parent, name := path.Split(p)
	parent = strings.TrimSuffix(parent, "/")
	atomic.AddInt64(&m.ops.Stat, 1)
	entries, e := m.ReadDir(parent, key, cancel)
	if e != nil {
		return Entry{}, e
	}
	for _, ent := range entries {
		if ent.Name == name {
			return ent, nil
		}
	}
	m.metaMu.Lock()
	m.neg[p] = now
	m.metaMu.Unlock()
	return Entry{}, newErr(ENOENT, CauseNotFound, "not found")
}

// MARK: - Reads

// ReadAt reads up to len(buf) bytes at off, but never past the block that
// contains off: a short read is legal and keeps every call within one block's
// deadline.
func (m *Mount) ReadAt(p string, off int64, buf []byte, key uint64, cancel <-chan struct{}) (int, *Error) {
	p = clean(p)
	ent, e := m.Stat(p, key, cancel)
	if e != nil {
		return 0, e
	}
	if ent.IsDir {
		return 0, newErr(EISDIR, CauseNone, "is a directory")
	}
	if off >= ent.Size {
		return 0, nil
	}
	bs := m.cfg.BlockSize
	idx := off / bs
	block, e := m.block(p, ent, idx, cancel)
	if e != nil {
		return 0, e
	}
	m.readAhead(p, ent, idx)
	n := copy(buf, block[off-idx*bs:])
	return n, nil
}

func blockKey(p string, ent Entry, idx int64) string {
	h := sha256.Sum256([]byte(fmt.Sprintf("%s\x00%d\x00%d\x00%d", p, ent.Size, ent.ModTime.UnixNano(), idx)))
	return hex.EncodeToString(h[:16])
}

func (m *Mount) block(p string, ent Entry, idx int64, cancel <-chan struct{}) ([]byte, *Error) {
	key := blockKey(p, ent, idx)
	if m.blocks != nil {
		if b, ok := m.blocks.get(key); ok {
			return b, nil
		}
	}
	start := idx * m.cfg.BlockSize
	end := min(start+m.cfg.BlockSize, ent.Size) - 1
	var data []byte
	e := m.run(opRead, 0, cancel, func(ctx context.Context, f fs.Fs) error {
		atomic.AddInt64(&m.ops.Read, 1)
		obj, err := f.NewObject(ctx, p)
		if err != nil {
			return err
		}
		if obj.Size() != ent.Size || !obj.ModTime(ctx).Equal(ent.ModTime) {
			return errStale
		}
		rc, err := obj.Open(ctx, &fs.RangeOption{Start: start, End: end})
		if err != nil {
			return err
		}
		defer rc.Close()
		data, err = io.ReadAll(rc)
		return err
	})
	if e != nil {
		if strings.Contains(e.Msg, errStale.Error()) {
			m.forgetDir(path.Dir(p))
			return nil, newErr(ESTALE, CauseNone, "file changed on the server")
		}
		return nil, e
	}
	if m.blocks != nil {
		m.blocks.put(key, data)
	}
	return data, nil
}

var errStale = fmt.Errorf("netfs: object changed since it was listed")

// readAhead fetches the next block in the background after two sequential
// reads, and only when a gate slot is free right now: it never queues behind
// or delays a real request.
func (m *Mount) readAhead(p string, ent Entry, idx int64) {
	m.seqMu.Lock()
	prev, seen := m.lastBlk[p]
	m.lastBlk[p] = idx
	m.seqMu.Unlock()
	next := idx + 1
	if !seen || prev != idx-1 || m.blocks == nil || next*m.cfg.BlockSize >= ent.Size {
		return
	}
	if _, ok := m.blocks.get(blockKey(p, ent, next)); ok {
		return
	}
	if len(m.sem) >= cap(m.sem)-1 {
		return
	}
	go func() { _, _ = m.block(p, ent, next, nil) }()
}

// MARK: - Rate limit

type tokenBucket struct {
	mu     sync.Mutex
	rate   float64
	burst  float64
	tokens float64
	last   time.Time
	now    func() time.Time
}

func newTokenBucket(rate float64, burst int, now func() time.Time) *tokenBucket {
	return &tokenBucket{rate: rate, burst: float64(burst), tokens: float64(burst), last: now(), now: now}
}

// wait takes one token, waiting at most maxWait for it.
func (t *tokenBucket) wait(maxWait time.Duration) bool {
	deadline := t.now().Add(maxWait)
	for {
		t.mu.Lock()
		now := t.now()
		t.tokens = min(t.burst, t.tokens+now.Sub(t.last).Seconds()*t.rate)
		t.last = now
		if t.tokens >= 1 {
			t.tokens--
			t.mu.Unlock()
			return true
		}
		need := time.Duration((1 - t.tokens) / t.rate * float64(time.Second))
		t.mu.Unlock()
		if now.Add(need).After(deadline) {
			return false
		}
		time.Sleep(need)
	}
}

// MARK: - Block cache (disk, LRU, tolerates being wiped)

type blockCache struct {
	mu    sync.Mutex
	dir   string
	limit int64
	total int64
	order []string // LRU, oldest first
	sizes map[string]int64
}

// newBlockCache indexes the blocks already in `dir`. [T-netmount-cache-index]
// It used to start empty: blocks from an earlier run (or an earlier Mount
// object for the same disk) were never counted, reused or evicted, so the
// directory grew past the cache limit while Go reported a smaller size.
// Keys hash path, size, mtime and block number, so an old block is still
// valid for an unchanged file. Oldest first by file time; then trimmed to
// the limit. Anything that is not a block file is removed.
func newBlockCache(dir string, limit int64) *blockCache {
	_ = os.MkdirAll(dir, 0o755)
	c := &blockCache{dir: dir, limit: limit, sizes: map[string]int64{}}
	type found struct {
		key  string
		size int64
		at   time.Time
	}
	var all []found
	if list, err := os.ReadDir(dir); err == nil {
		for _, de := range list {
			info, err := de.Info()
			if err != nil {
				continue
			}
			if !info.Mode().IsRegular() || !isBlockKey(de.Name()) {
				_ = os.RemoveAll(filepath.Join(dir, de.Name()))
				continue
			}
			all = append(all, found{de.Name(), info.Size(), info.ModTime()})
		}
	}
	sort.Slice(all, func(i, j int) bool { return all[i].at.Before(all[j].at) })
	for _, f := range all {
		c.sizes[f.key] = f.size
		c.total += f.size
		c.order = append(c.order, f.key)
	}
	for c.total > c.limit && len(c.order) > 0 {
		c.dropLocked(c.order[0])
	}
	return c
}

// isBlockKey: the 32 lowercase hex characters blockKey produces.
func isBlockKey(name string) bool {
	if len(name) != 32 {
		return false
	}
	for _, r := range name {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f') {
			return false
		}
	}
	return true
}

func (c *blockCache) get(key string) ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.sizes[key]; !ok {
		return nil, false
	}
	b, err := os.ReadFile(filepath.Join(c.dir, key))
	if err != nil {
		// iOS purged Caches: forget it and fetch again.
		c.dropLocked(key)
		return nil, false
	}
	c.touchLocked(key)
	return b, true
}

func (c *blockCache) put(key string, b []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.sizes[key]; ok {
		c.touchLocked(key)
		return
	}
	_ = os.MkdirAll(c.dir, 0o755)
	if err := os.WriteFile(filepath.Join(c.dir, key), b, 0o644); err != nil {
		return
	}
	c.sizes[key] = int64(len(b))
	c.total += int64(len(b))
	c.order = append(c.order, key)
	for c.total > c.limit && len(c.order) > 1 {
		c.dropLocked(c.order[0])
	}
}

func (c *blockCache) touchLocked(key string) {
	for i, k := range c.order {
		if k == key {
			c.order = append(append(c.order[:i:i], c.order[i+1:]...), key)
			return
		}
	}
}

func (c *blockCache) dropLocked(key string) {
	if sz, ok := c.sizes[key]; ok {
		c.total -= sz
		delete(c.sizes, key)
	}
	for i, k := range c.order {
		if k == key {
			c.order = append(c.order[:i:i], c.order[i+1:]...)
			break
		}
	}
	_ = os.Remove(filepath.Join(c.dir, key))
}

func (c *blockCache) size() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.total
}
