package netfs

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	_ "github.com/OpenMinis/minis-rclone/backends"
	"github.com/rclone/rclone/backend/webdav/api"
	"golang.org/x/net/webdav"
)

// MARK: - Test server: WebDAV over a temp dir, behind a fault proxy

type proxyMode int32

const (
	modePass proxyMode = iota
	modeHang           // accept, then never answer
	modeSlow           // ~bytesPerSec in each direction
	modeRefuse         // close at once (connection reset)
)

type server struct {
	t        *testing.T
	root     string
	http     *http.Server
	backend  net.Listener
	front    net.Listener
	mode     atomic.Int32
	slowBps  atomic.Int64
	requests atomic.Int64
	user     string
	pass     string
	// forbid: requests under this path prefix get 403 (a share rule).
	forbid   atomic.Value
	conns    sync.WaitGroup
	closing  chan struct{}
	addr     string
	liveMu   sync.Mutex
	live     map[net.Conn]struct{}
}

// refuse makes the server really unreachable: the port is closed (new
// connections get ECONNREFUSED) and every open connection is cut, so pooled
// keep-alive connections cannot carry on. unrefuse listens again on the same
// address.
func (s *server) refuse() {
	_ = s.front.Close()
	s.liveMu.Lock()
	for c := range s.live {
		_ = c.Close()
	}
	s.liveMu.Unlock()
}

// hang makes every request hang from now on, including ones on keep-alive
// connections that were idle when the mode changed (those are cut, so the
// client has to dial a new one).
func (s *server) hang() {
	s.mode.Store(int32(modeHang))
	s.liveMu.Lock()
	for c := range s.live {
		_ = c.Close()
	}
	s.liveMu.Unlock()
	// Let the client's transport see those closes and drop the idle
	// connections. Otherwise the next request can still be written on one
	// and fail at once with EOF (an "other" failure), not hang — the test
	// is about a server that accepts and then never answers.
	time.Sleep(50 * time.Millisecond)
}

func (s *server) unrefuse() {
	var err error
	for i := 0; i < 50; i++ {
		if s.front, err = net.Listen("tcp", s.addr); err == nil {
			go s.acceptLoop()
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	s.t.Fatalf("relisten %s: %v", s.addr, err)
}

func newServer(t *testing.T, user, pass string) *server {
	t.Helper()
	s := &server{t: t, root: t.TempDir(), user: user, pass: pass, closing: make(chan struct{}), live: map[net.Conn]struct{}{}}
	h := &webdav.Handler{FileSystem: webdav.Dir(s.root), LockSystem: webdav.NewMemLS()}
	var err error
	s.backend, err = net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s.http = &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.requests.Add(1)
		if s.user != "" {
			u, p, ok := r.BasicAuth()
			if !ok || u != s.user || p != s.pass {
				w.Header().Set("WWW-Authenticate", `Basic realm="t"`)
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
		}
		if p, _ := s.forbid.Load().(string); p != "" && strings.HasPrefix(r.URL.Path, p) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		h.ServeHTTP(w, r)
	})}
	go func() { _ = s.http.Serve(s.backend) }()
	s.front, err = net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s.addr = s.front.Addr().String()
	go s.acceptLoop()
	t.Cleanup(s.close)
	return s
}

func (s *server) url() string { return "http://" + s.addr + "/" }

func (s *server) acceptLoop() {
	for {
		c, err := s.front.Accept()
		if err != nil {
			return
		}
		s.conns.Add(1)
		s.liveMu.Lock()
		s.live[c] = struct{}{}
		s.liveMu.Unlock()
		go func() {
			defer s.conns.Done()
			s.handle(c)
			s.liveMu.Lock()
			delete(s.live, c)
			s.liveMu.Unlock()
		}()
	}
}

func (s *server) handle(c net.Conn) {
	defer c.Close()
	switch proxyMode(s.mode.Load()) {
	case modeRefuse:
		if tc, ok := c.(*net.TCPConn); ok {
			_ = tc.SetLinger(0)
		}
		return
	case modeHang:
		select {
		case <-s.closing:
		case <-time.After(10 * time.Minute):
		}
		return
	}
	b, err := net.Dial("tcp", s.backend.Addr().String())
	if err != nil {
		return
	}
	defer b.Close()
	cp := func(dst, src net.Conn) {
		buf := make([]byte, 4096)
		for {
			if proxyMode(s.mode.Load()) == modeHang {
				<-s.closing
				return
			}
			n, err := src.Read(buf)
			if n > 0 {
				if proxyMode(s.mode.Load()) == modeSlow {
					time.Sleep(time.Duration(float64(n) / float64(s.slowBps.Load()) * float64(time.Second)))
				}
				if _, werr := dst.Write(buf[:n]); werr != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}
	done := make(chan struct{}, 2)
	go func() { cp(b, c); done <- struct{}{} }()
	go func() { cp(c, b); done <- struct{}{} }()
	select {
	case <-done:
	case <-s.closing:
	}
}

func (s *server) close() {
	select {
	case <-s.closing:
		return
	default:
	}
	close(s.closing)
	_ = s.front.Close()
	_ = s.http.Close()
}

func (s *server) write(rel string, data []byte) {
	p := filepath.Join(s.root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		s.t.Fatal(err)
	}
	if err := os.WriteFile(p, data, 0o644); err != nil {
		s.t.Fatal(err)
	}
}

// MARK: - Helpers

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) now() time.Time   { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *fakeClock) add(d time.Duration) { c.mu.Lock(); c.t = c.t.Add(d); c.mu.Unlock() }

func mount(t *testing.T, s *server, mutate func(*Config)) *Mount {
	t.Helper()
	cfg := Config{
		Name: "t", Type: "webdav",
		Params:   map[string]string{"url": s.url(), "vendor": "other", "user": s.user, "pass": s.pass},
		CacheDir: t.TempDir(),
		// Test-sized bounds; the production values are the defaults.
		ConnectTimeout: 2 * time.Second, IOTimeout: 2 * time.Second,
		MetaTimeout: 2 * time.Second, ListTimeout: 2 * time.Second, ReadTimeout: 3 * time.Second, QueueWait: 1 * time.Second,
		Backoff: []time.Duration{300 * time.Millisecond, 600 * time.Millisecond},
	}
	if mutate != nil {
		mutate(&cfg)
	}
	m, err := NewMount(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func errnoOf(e *Error) int {
	if e == nil {
		return 0
	}
	return e.Errno
}

func timed(f func()) time.Duration {
	start := time.Now()
	f()
	return time.Since(start)
}

// MARK: - Tests

func TestListStatRead(t *testing.T) {
	s := newServer(t, "", "")
	big := bytes.Repeat([]byte("0123456789abcdef"), 200_000) // 3.2 MB, 4 blocks
	s.write("docs/a.txt", []byte("hello netfs\n"))
	s.write("docs/sub/b.md", []byte("# b\n"))
	s.write("big.bin", big)
	s.write("中文 名.txt", []byte("x"))
	m := mount(t, s, nil)

	root, e := m.ReadDir("", 0, nil)
	if e != nil {
		t.Fatalf("readdir root: %v", e)
	}
	names := []string{}
	for _, it := range root {
		names = append(names, it.Name)
	}
	if fmt.Sprint(names) != "[big.bin docs 中文 名.txt]" {
		t.Fatalf("root listing %v", names)
	}
	if ent, e := m.Stat("/docs/a.txt", 0, nil); e != nil || ent.Size != 12 || ent.IsDir {
		t.Fatalf("stat a.txt %+v %v", ent, e)
	}
	if ent, e := m.Stat("docs/sub", 0, nil); e != nil || !ent.IsDir {
		t.Fatalf("stat sub %+v %v", ent, e)
	}
	if _, e := m.Stat("docs/missing", 0, nil); errnoOf(e) != ENOENT {
		t.Fatalf("missing: %v", e)
	}
	if ent, e := m.Stat("", 0, nil); e != nil || !ent.IsDir {
		t.Fatalf("root stat must be local: %v", e)
	}
	// Whole big file through 1 MiB-bounded reads.
	var got bytes.Buffer
	buf := make([]byte, 256<<10)
	reads := 0
	readTime := timed(func() {
		for off := int64(0); ; {
			n, e := m.ReadAt("big.bin", off, buf, 0, nil)
			if e != nil {
				t.Fatalf("read at %d: %v", off, e)
			}
			if n == 0 {
				break
			}
			got.Write(buf[:n])
			off += int64(n)
			reads++
		}
	})
	if !bytes.Equal(got.Bytes(), big) {
		t.Fatalf("big.bin content mismatch: %d bytes", got.Len())
	}
	st := m.Status()
	t.Logf("big.bin %d bytes in %d reads, %v; network block fetches=%d (4 blocks), state=%s",
		len(big), reads, readTime, st.Ops.Read, st.State)
	if st.State != StateOnline {
		t.Fatalf("state %s", st.State)
	}
	// Listing again within the TTL is free.
	before := s.requests.Load()
	_, _ = m.ReadDir("docs", 0, nil)
	_, _ = m.Stat("docs/a.txt", 0, nil)
	if s.requests.Load() != before {
		t.Fatalf("cached listing went to the network")
	}
}

func TestTimeoutOnHangAndBoundedGoroutines(t *testing.T) {
	s := newServer(t, "", "")
	s.write("x.txt", []byte("x"))
	s.mode.Store(int32(modeHang))
	m := mount(t, s, func(c *Config) { c.FailThreshold = 1000; c.TimeoutThreshold = 1000 }) // keep the breaker out of this test
	baseline := runtime.NumGoroutine()
	var e *Error
	d := timed(func() { _, e = m.ReadDir("", 0, nil) })
	if errnoOf(e) != ETIMEDOUT {
		t.Fatalf("hang: want ETIMEDOUT, got %v", e)
	}
	t.Logf("server accepts then hangs: readdir returned ETIMEDOUT after %v (MetaTimeout 2s)", d.Round(time.Millisecond))
	if d > 2500*time.Millisecond {
		t.Fatalf("returned after %v, deadline is 2s", d)
	}
	// 20 callers at once against a hung server.
	var wg sync.WaitGroup
	var peak atomic.Int64
	errs := make(chan int, 20)
	start := time.Now()
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, e := m.ReadDir(fmt.Sprintf("d%d", i), 0, nil)
			errs <- errnoOf(e)
			if v := m.inFlight.Load(); v > peak.Load() {
				peak.Store(v)
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	all := time.Since(start)
	for e := range errs {
		if e != ETIMEDOUT {
			t.Fatalf("want ETIMEDOUT for every caller, got %d", e)
		}
	}
	extra := runtime.NumGoroutine() - baseline
	t.Logf("20 concurrent callers on a hung server: all ETIMEDOUT in %v; peak in-flight=%d (cap %d); goroutines above baseline=%d",
		all.Round(time.Millisecond), peak.Load(), m.cfg.MaxConcurrent, extra)
	if peak.Load() > int64(m.cfg.MaxConcurrent) {
		t.Fatalf("in-flight %d over the cap %d", peak.Load(), m.cfg.MaxConcurrent)
	}
	if all > 6*time.Second {
		t.Fatalf("callers waited %v", all)
	}
}

func TestRefusedBreakerHalfOpenRecovery(t *testing.T) {
	s := newServer(t, "", "")
	s.write("a.txt", []byte("a"))
	var transitions []string
	var tmu sync.Mutex
	m := mount(t, s, func(c *Config) {
		c.OnTransition = func(name string, from, to State, st Status) {
			tmu.Lock()
			transitions = append(transitions, fmt.Sprintf("%s->%s(%s)", from, to, st.LastCause))
			tmu.Unlock()
		}
	})
	if _, e := m.ReadDir("", 0, nil); e != nil {
		t.Fatal(e)
	}
	s.refuse()
	// Fresh listing needed for each call: use different dirs.
	codes := []int{}
	for i := 0; i < 3; i++ {
		_, e := m.ReadDir(fmt.Sprintf("x%d", i), 0, nil)
		codes = append(codes, errnoOf(e))
	}
	st := m.Status()
	if st.State != StateOffline {
		t.Fatalf("after 3 failures want offline, got %s (%v)", st.State, codes)
	}
	// Offline: no network, fast.
	before := s.requests.Load()
	var e *Error
	d := timed(func() { _, e = m.ReadDir("y", 0, nil) })
	t.Logf("server refusing: errnos %v, then offline fast-fail errno=%d in %v, lastCause=%s, retryAt in %v",
		codes, errnoOf(e), d, st.LastCause, time.Until(st.RetryAt).Round(10*time.Millisecond))
	if d > 50*time.Millisecond || s.requests.Load() != before {
		t.Fatalf("offline call took %v or hit the network", d)
	}
	// Stale listing still served while offline.
	if _, e := m.ReadDir("", 0, nil); e != nil {
		t.Fatalf("cached root while offline: %v", e)
	}
	// Server back; after the backoff one probe recovers.
	s.unrefuse()
	time.Sleep(350 * time.Millisecond)
	var wg sync.WaitGroup
	results := make(chan int, 5)
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func(i int) { defer wg.Done(); _, e := m.ReadDir(fmt.Sprintf("p%d", i), 0, nil); results <- errnoOf(e) }(i)
	}
	wg.Wait()
	close(results)
	ok, fast := 0, 0
	for r := range results {
		if r == 0 || r == ENOENT {
			ok++
		} else {
			fast++
		}
	}
	time.Sleep(50 * time.Millisecond)
	tmu.Lock()
	t.Logf("recovery: %d of 5 concurrent calls went out (half-open admits one), %d failed fast; state=%s; transitions=%v",
		ok, fast, m.Status().State, transitions)
	tmu.Unlock()
	if m.Status().State != StateOnline {
		t.Fatalf("did not recover")
	}
}

func TestAuthFailureNotRetried(t *testing.T) {
	s := newServer(t, "alice", "right")
	s.write("a.txt", []byte("a"))
	s.pass = "right"
	m := mount(t, s, func(c *Config) { c.Params["pass"] = "wrong" })
	_, e := m.ReadDir("", 0, nil)
	if errnoOf(e) != EACCES || m.Status().State != StateAuthFailed {
		t.Fatalf("want EACCES/auth-failed, got %v %s", e, m.Status().State)
	}
	before := s.requests.Load()
	for i := 0; i < 10; i++ {
		_, _ = m.ReadDir(fmt.Sprintf("z%d", i), 0, nil)
	}
	t.Logf("wrong password: EACCES, state=%s; 10 more calls sent %d requests", m.Status().State, s.requests.Load()-before)
	if s.requests.Load() != before {
		t.Fatalf("auth-failed mount retried")
	}
	// Right password through a fresh mount works (passwords are obscured in memory).
	m2 := mount(t, s, func(c *Config) { c.Params["pass"] = "right" })
	if _, e := m2.ReadDir("", 0, nil); e != nil {
		t.Fatalf("right password: %v", e)
	}
}

// [T-netmount-403-per-path] One folder the account may not read answers 403.
// That is EACCES for that path only: the mount stays usable, never
// auth-failed, and the rest of the disk keeps working.
func TestForbiddenPathDoesNotLatchMount(t *testing.T) {
	s := newServer(t, "alice", "right")
	s.write("ok/a.txt", []byte("a"))
	s.write("private/b.txt", []byte("b"))
	s.forbid.Store("/private")
	m := mount(t, s, func(c *Config) { c.Params["pass"] = "right" })
	for i := 0; i < 5; i++ {
		_, e := m.ReadDir("private", 0, nil)
		if errnoOf(e) != EACCES || e.Cause != CauseForbidden {
			t.Fatalf("forbidden folder: want EACCES/forbidden, got %v", e)
		}
	}
	if st := m.Status().State; st == StateAuthFailed || st == StateOffline || st == StateDegraded {
		t.Fatalf("one forbidden folder changed the mount state to %s", st)
	}
	if _, e := m.ReadDir("ok", 0, nil); e != nil {
		t.Fatalf("rest of the disk after a 403: %v", e)
	}
	t.Logf("403 x5 -> EACCES each, state=%s, other folder still readable", m.Status().State)
}

func TestClassify403And401(t *testing.T) {
	cases := []struct {
		err  error
		want Cause
	}{
		{&api.Error{StatusCode: 401}, CauseAuth},
		{&api.Error{StatusCode: 403}, CauseForbidden},
		{errors.New("HTTP 403 Forbidden"), CauseForbidden},
		{errors.New("AccessDenied: Access Denied"), CauseForbidden},
		{errors.New("InvalidAccessKeyId: The AWS Access Key Id you provided does not exist"), CauseAuth},
		{errors.New("SignatureDoesNotMatch: 403"), CauseAuth},
		{errors.New("401 Unauthorized"), CauseAuth},
		{errors.New("STATUS_LOGON_FAILURE logon failure"), CauseAuth},
	}
	for _, c := range cases {
		if got := classify(c.err); got != c.want {
			t.Errorf("classify(%q) = %s, want %s", c.err, got, c.want)
		}
	}
	if CauseForbidden.String() != "forbidden" || CauseForbidden.Errno() != EACCES {
		t.Fatalf("forbidden: %s / %d", CauseForbidden, CauseForbidden.Errno())
	}
}

// [T-netmount-list-timeout] A big folder whose listing outlasts a stat's
// deadline still lists (it has ListTimeout), and the mount stays online; a
// stat with the same short deadline would have timed out.
func TestBigListingUsesListTimeout(t *testing.T) {
	s := newServer(t, "", "")
	for i := 0; i < 400; i++ {
		s.write(fmt.Sprintf("big/photo-%04d-with-a-long-name.jpg", i), []byte("x"))
	}
	m := mount(t, s, func(c *Config) {
		c.MetaTimeout = 300 * time.Millisecond
		c.ListTimeout = 10 * time.Second
	})
	if _, e := m.Stat("", 0, nil); e != nil {
		t.Fatal(e)
	}
	s.slowBps.Store(40 << 10) // ~40 KB/s: the 400-entry PROPFIND takes well over 300 ms
	s.mode.Store(int32(modeSlow))
	var entries []Entry
	var e *Error
	d := timed(func() { entries, e = m.ReadDir("big", 0, nil) })
	t.Logf("400-entry listing over a slow link: %d entries in %v (MetaTimeout 300ms, ListTimeout 10s), state=%s",
		len(entries), d.Round(10*time.Millisecond), m.Status().State)
	if e != nil || len(entries) != 400 {
		t.Fatalf("big listing: %v, %d entries", e, len(entries))
	}
	if d < 300*time.Millisecond {
		t.Fatalf("listing was not slower than MetaTimeout (%v); the test proves nothing", d)
	}
	if st := m.Status().State; st != StateOnline {
		t.Fatalf("state after a slow listing: %s", st)
	}
}

// [T-netmount-cache-index] A new cache indexes what is already on disk: it
// trims an over-limit directory (oldest first), removes stray files, and a
// later Mount for the same disk reuses earlier blocks instead of re-fetching.
func TestBlockCacheIndexesExistingBlocks(t *testing.T) {
	dir := t.TempDir()
	base := time.Now().Add(-time.Hour)
	for i := 0; i < 6; i++ {
		key := fmt.Sprintf("%032x", i)
		p := filepath.Join(dir, key)
		if err := os.WriteFile(p, bytes.Repeat([]byte{byte(i)}, 100), 0o644); err != nil {
			t.Fatal(err)
		}
		at := base.Add(time.Duration(i) * time.Minute)
		_ = os.Chtimes(p, at, at)
	}
	_ = os.WriteFile(filepath.Join(dir, "partial.tmp"), []byte("junk"), 0o644)
	c := newBlockCache(dir, 350) // room for three 100-byte blocks
	if c.size() > 350 || len(c.order) != 3 {
		t.Fatalf("over-limit cache not trimmed: size %d, %d blocks", c.size(), len(c.order))
	}
	if _, ok := c.get(fmt.Sprintf("%032x", 0)); ok {
		t.Fatalf("oldest block kept")
	}
	if b, ok := c.get(fmt.Sprintf("%032x", 5)); !ok || len(b) != 100 || b[0] != 5 {
		t.Fatalf("newest block not reusable")
	}
	if _, err := os.Stat(filepath.Join(dir, "partial.tmp")); !os.IsNotExist(err) {
		t.Fatalf("stray file not removed")
	}
	left, _ := os.ReadDir(dir)
	if len(left) != 3 {
		t.Fatalf("directory holds %d files, index says 3", len(left))
	}

	// A second Mount on the same cache directory reads from it.
	s := newServer(t, "", "")
	s.write("f.bin", bytes.Repeat([]byte("z"), 3<<20))
	cacheDir := t.TempDir()
	readAll := func(m *Mount) int {
		buf := make([]byte, 1<<20)
		total := 0
		for {
			n, e := m.ReadAt("f.bin", int64(total), buf, 0, nil)
			if e != nil {
				t.Fatalf("read at %d: %v", total, e)
			}
			if n == 0 {
				return total
			}
			total += n
		}
	}
	m1 := mount(t, s, func(c *Config) { c.CacheDir = cacheDir })
	if n := readAll(m1); n != 3<<20 {
		t.Fatalf("first mount read %d bytes", n)
	}
	m2 := mount(t, s, func(c *Config) { c.CacheDir = cacheDir })
	before := s.requests.Load()
	if n := readAll(m2); n != 3<<20 {
		t.Fatalf("second mount read %d bytes", n)
	}
	reads := s.requests.Load() - before
	t.Logf("second Mount on the same cache: %d server requests for a 3 MB file (blocks reused)", reads)
	if reads > 1 { // at most the stat
		t.Fatalf("second Mount re-fetched cached blocks: %d requests", reads)
	}
}

func TestSlowNetwork(t *testing.T) {
	s := newServer(t, "", "")
	data := bytes.Repeat([]byte{7}, 300_000)
	s.write("f.bin", data)
	m := mount(t, s, func(c *Config) { c.BlockSize = 256 << 10; c.ReadTimeout = 8 * time.Second })
	if _, e := m.Stat("f.bin", 0, nil); e != nil {
		t.Fatal(e)
	}
	s.slowBps.Store(64 << 10)
	s.mode.Store(int32(modeSlow))
	buf := make([]byte, 256<<10)
	var n int
	var e *Error
	d := timed(func() { n, e = m.ReadAt("f.bin", 0, buf, 0, nil) })
	t.Logf("64 KB/s link: first 256 KiB block n=%d err=%v in %v", n, e, d.Round(time.Millisecond))
	if e != nil {
		t.Fatalf("slow read failed: %v", e)
	}
	// Same link with a block too large for the deadline → ETIMEDOUT, bounded.
	m2 := mount(t, s, func(c *Config) { c.BlockSize = 1 << 20; c.ReadTimeout = 2 * time.Second })
	s.mode.Store(int32(modePass))
	_, _ = m2.Stat("f.bin", 0, nil)
	s.mode.Store(int32(modeSlow))
	s.slowBps.Store(16 << 10)
	d = timed(func() { _, e = m2.ReadAt("f.bin", 0, make([]byte, 1<<20), 0, nil) })
	t.Logf("16 KB/s link, 300 KB block, 2s deadline: errno=%d after %v", errnoOf(e), d.Round(time.Millisecond))
	if errnoOf(e) != ETIMEDOUT || d > 2500*time.Millisecond {
		t.Fatalf("want bounded ETIMEDOUT, got %v after %v", e, d)
	}
}

func TestOneStuckMountDoesNotAffectAnother(t *testing.T) {
	stuck := newServer(t, "", "")
	stuck.mode.Store(int32(modeHang))
	healthy := newServer(t, "", "")
	healthy.write("ok.txt", []byte("ok"))
	ms := mount(t, stuck, nil)
	mh := mount(t, healthy, nil)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) { defer wg.Done(); _, _ = ms.ReadDir(fmt.Sprintf("s%d", i), 0, nil) }(i)
	}
	time.Sleep(100 * time.Millisecond)
	var e *Error
	d := timed(func() { _, e = mh.Stat("ok.txt", 0, nil) })
	wg.Wait()
	t.Logf("while 8 calls hang on mount A, mount B stat took %v (err=%v)", d.Round(time.Millisecond), e)
	if e != nil || d > 500*time.Millisecond {
		t.Fatalf("healthy mount affected: %v after %v", e, d)
	}
}

func TestBudgetAndRate(t *testing.T) {
	s := newServer(t, "", "")
	for i := 0; i < 60; i++ {
		s.write(fmt.Sprintf("d%02d/f.txt", i), []byte("x"))
	}
	m := mount(t, s, func(c *Config) { c.CallBudgetOps = 25; c.RatePerSec = 1000; c.RateBurst = 1000 })
	const key = 42
	listed, failed := 0, 0
	for i := 0; i < 60; i++ {
		if _, e := m.ReadDir(fmt.Sprintf("d%02d", i), key, nil); e == nil {
			listed++
		} else if e.Errno == ETIMEDOUT {
			failed++
		}
	}
	t.Logf("budget 25 requests/key: %d listings served, %d refused with ETIMEDOUT", listed, failed)
	if listed != 25 || failed != 35 {
		t.Fatalf("budget not enforced: %d/%d", listed, failed)
	}
	m.ResetBudget(key)
	if _, e := m.ReadDir("d59", key, nil); e != nil {
		t.Fatalf("after reset: %v", e)
	}
	// Rate: 5/s, burst 5 → 15 uncached listings need ~2 s.
	m2 := mount(t, s, func(c *Config) { c.RatePerSec = 5; c.RateBurst = 5; c.QueueWait = 5 * time.Second })
	d := timed(func() {
		for i := 0; i < 15; i++ {
			_, _ = m2.ReadDir(fmt.Sprintf("d%02d", i), 0, nil)
		}
	})
	t.Logf("rate 5/s burst 5: 15 listings took %v", d.Round(10*time.Millisecond))
	if d < 1800*time.Millisecond {
		t.Fatalf("rate limit not applied: %v", d)
	}
}

func TestNoNetworkForMountRootAndNegativeCache(t *testing.T) {
	s := newServer(t, "", "")
	s.mode.Store(int32(modeHang))
	m := mount(t, s, nil)
	d := timed(func() {
		if ent, e := m.Stat("/", 0, nil); e != nil || !ent.IsDir {
			t.Fatalf("root stat: %v", e)
		}
	})
	if d > 10*time.Millisecond || s.requests.Load() != 0 {
		t.Fatalf("root stat touched the network (%v)", d)
	}
	s.mode.Store(int32(modePass))
	s.write("real.txt", []byte("x"))
	_, _ = m.ReadDir("", 0, nil)
	_, e := m.Stat("nope", 0, nil)
	if errnoOf(e) != ENOENT {
		t.Fatal(e)
	}
	before := s.requests.Load()
	for i := 0; i < 5; i++ {
		_, _ = m.Stat("nope", 0, nil)
	}
	if s.requests.Load() != before {
		t.Fatalf("negative lookups hit the network")
	}
}

func TestNoConfigFileWritten(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	s := newServer(t, "u", "secret-pass")
	s.write("a.txt", []byte("a"))
	m := mount(t, s, func(c *Config) { c.Params["user"] = "u"; c.Params["pass"] = "secret-pass" })
	if _, e := m.ReadDir("", 0, nil); e != nil {
		t.Fatal(e)
	}
	var files []string
	_ = filepath.Walk(home, func(p string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			files = append(files, p)
		}
		return nil
	})
	if len(files) != 0 {
		t.Fatalf("files written under HOME: %v", files)
	}
	_ = io.Discard
}

func TestCancelReturnsAtOnce(t *testing.T) {
	s := newServer(t, "", "")
	s.mode.Store(int32(modeHang))
	m := mount(t, s, func(c *Config) { c.MetaTimeout = 5 * time.Second })
	cancel := make(chan struct{})
	go func() { time.Sleep(200 * time.Millisecond); close(cancel) }()
	var e *Error
	d := timed(func() { _, e = m.ReadDir("x", 0, cancel) })
	t.Logf("hung server, cancel after 200ms: errno=%d after %v (deadline 5s)", errnoOf(e), d.Round(time.Millisecond))
	if errnoOf(e) != EINTR || d > 400*time.Millisecond {
		t.Fatalf("want EINTR right after cancel, got %v after %v", e, d)
	}
	// Cancel while queued for a gate slot.
	m2 := mount(t, s, func(c *Config) { c.MaxConcurrent = 1; c.QueueWait = 5 * time.Second; c.FailThreshold = 1000; c.TimeoutThreshold = 1000 })
	go func() { _, _ = m2.ReadDir("busy", 0, nil) }()
	time.Sleep(100 * time.Millisecond)
	cancel2 := make(chan struct{})
	go func() { time.Sleep(150 * time.Millisecond); close(cancel2) }()
	d = timed(func() { _, e = m2.ReadDir("queued", 0, cancel2) })
	t.Logf("queued behind a hung call, cancel after 150ms: errno=%d after %v", errnoOf(e), d.Round(time.Millisecond))
	if errnoOf(e) != EINTR || d > 400*time.Millisecond {
		t.Fatalf("queued call not cancelled: %v after %v", e, d)
	}
}

func TestBudgetWindowEndsAfterIdleGap(t *testing.T) {
	s := newServer(t, "", "")
	for i := 0; i < 80; i++ {
		s.write(fmt.Sprintf("e%02d/f.txt", i), []byte("x"))
	}
	clock := &fakeClock{t: time.Unix(1_800_000_000, 0)}
	m := mount(t, s, func(c *Config) {
		c.Now = clock.now
		c.CallBudgetOps = 3
		c.CallBudgetTime = 60 * time.Second
		c.BudgetIdleGap = 3 * time.Second
		c.RatePerSec = 1e6
		c.RateBurst = 1e6
	})
	ok := func(dir string) bool { _, e := m.ReadDir(dir, 7, nil); return e == nil }
	// One burst: 3 allowed, the 4th refused.
	got := []bool{ok("e00"), ok("e01"), ok("e02"), ok("e03")}
	// Idle 5 s: a new command, a new window.
	clock.add(5 * time.Second)
	got = append(got, ok("e04"))
	// A long-running command: 70 s of steady requests 1 s apart is refused
	// once it passes 60 s, idle gap or not. A new directory each time, so no
	// cached listing can stand in for the refused request.
	m2 := mount(t, s, func(c *Config) {
		c.Now = clock.now
		c.CallBudgetOps = 1000
		c.RatePerSec = 1e6
		c.RateBurst = 1e6
		c.DirCacheTTL = time.Nanosecond
	})
	refusedAt := -1
	for i := 0; i < 70; i++ {
		if _, e := m2.ReadDir(fmt.Sprintf("e%02d", i+5), 9, nil); e != nil && refusedAt < 0 {
			refusedAt = i
		}
		clock.add(time.Second)
	}
	t.Logf("burst: %v; steady 1/s scan refused from second %d", got, refusedAt)
	if fmt.Sprint(got) != "[true true true false true]" || refusedAt != 60 {
		t.Fatalf("budget window wrong: %v, refused at %d", got, refusedAt)
	}
}

func TestTimeoutsTripFasterAndProbeIsShort(t *testing.T) {
	s := newServer(t, "", "")
	s.write("a.txt", []byte("a"))
	m := mount(t, s, func(c *Config) {
		c.MetaTimeout = 2 * time.Second
		c.ProbeTimeout = 500 * time.Millisecond
		c.Backoff = []time.Duration{300 * time.Millisecond}
	})
	if _, e := m.ReadDir("", 0, nil); e != nil {
		t.Fatal(e)
	}
	s.hang()
	_, _ = m.ReadDir("t1", 0, nil)
	st1 := m.Status().State
	_, _ = m.ReadDir("t2", 0, nil)
	st2 := m.Status().State
	time.Sleep(350 * time.Millisecond)
	var e *Error
	d := timed(func() { _, e = m.ReadDir("t3", 0, nil) })
	t.Logf("after 1 timeout: %s; after 2: %s; half-open probe on a hung server took %v (errno %d)",
		st1, st2, d.Round(10*time.Millisecond), errnoOf(e))
	if st1 != StateDegraded || st2 != StateOffline {
		t.Fatalf("want degraded then offline after 2 timeouts, got %s, %s", st1, st2)
	}
	if d > 800*time.Millisecond || errnoOf(e) != ETIMEDOUT {
		t.Fatalf("probe should use the short deadline: %v %v", d, e)
	}
}
