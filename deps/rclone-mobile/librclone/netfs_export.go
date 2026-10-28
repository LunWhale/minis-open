package main

// C entry points for network mounts (deps/rclone-mobile/netfs).
//
// They mirror the iSH netfs host-callback table (deps/ish/fs/netfs.h) one to
// one, but this library does not include or link iSH: the app's thin layer
// (ISHKernel.m) fills iSH's table with small C functions that call these.
// Contract details are in netfs.h; the important ones here:
//   - results are 0 or a POSITIVE LINUX errno;
//   - calls may block, but return by their own deadline (netfs.Config);
//   - MinisNetfsCancel(call) may arrive from another thread at any time,
//     also before the call itself started or after it ended;
//   - buffers handed in are only written before the call returns.

/*
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char name[256];
    uint64_t size;
    int64_t mtime_sec;
    int32_t mtime_nsec;
    int32_t is_dir;
} minis_netfs_dirent;

typedef void (*minis_netfs_log_fn)(const char *line);
static void minis_netfs_call_log(minis_netfs_log_fn fn, const char *line) { if (fn) fn(line); }
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/OpenMinis/minis-rclone/netfs"
)

// MARK: - Mount registry

type netfsConfigJSON struct {
	ID         string            `json:"id"`
	Name       string            `json:"name"`
	Type       string            `json:"type"`
	Params     map[string]string `json:"params"`
	Root       string            `json:"root"`
	CacheDir   string            `json:"cacheDir"`
	CacheLimit int64             `json:"cacheLimitBytes"`
	// TrustedCertSHA256: a self-signed certificate the user trusted (Q8).
	TrustedCertSHA256 string `json:"trustedCertSHA256"`
}

func (c netfsConfigJSON) config() netfs.Config {
	return netfs.Config{
		Name: c.Name, Type: c.Type, Params: c.Params, Root: c.Root,
		CacheDir: c.CacheDir, CacheLimit: c.CacheLimit, TrustedCertSHA256: c.TrustedCertSHA256,
	}
}

var (
	netfsMu      sync.Mutex
	netfsByID    = map[string]*netfs.Mount{}
	// handle → mount id. Resolved through netfsByID on every call, so a mount
	// reconfigured in Settings (new address, login, certificate) is what the
	// already-attached iSH mount uses from its next request on, and a removed
	// one answers ENOTCONN.
	netfsHandles = map[uint64]string{}
	netfsNext    uint64 = 1
	netfsLog     C.minis_netfs_log_fn
)

// MinisNetfsSetLogger registers where state-change lines go (the app forwards
// them to iSH's netfs_log_transition, i.e. dmesg).
//
//export MinisNetfsSetLogger
func MinisNetfsSetLogger(fn C.minis_netfs_log_fn) {
	netfsMu.Lock()
	netfsLog = fn
	netfsMu.Unlock()
}

func netfsEmit(line string) {
	netfsMu.Lock()
	fn := netfsLog
	netfsMu.Unlock()
	if fn == nil {
		return
	}
	cs := C.CString(line)
	C.minis_netfs_call_log(fn, cs)
	C.free(unsafe.Pointer(cs))
}

// transitionLine is the dmesg text for a state change, NFS style: written on
// edges only, never per failed request. "" means not worth a line.
func transitionLine(from, to netfs.State, st netfs.Status) string {
	who := fmt.Sprintf("%s (%s %s)", st.Name, st.Type, st.Server)
	switch to {
	case netfs.StateDegraded:
		return fmt.Sprintf("%s: not responding (%s), still trying", who, st.LastCause)
	case netfs.StateOffline:
		return fmt.Sprintf("%s: offline (%s), next try in %s", who, st.LastCause,
			time.Until(st.RetryAt).Round(time.Second))
	case netfs.StateAuthFailed:
		return fmt.Sprintf("%s: authentication failed, not retrying until the login is updated", who)
	case netfs.StateOnline:
		if from == netfs.StateConnecting {
			return fmt.Sprintf("%s: connected", who)
		}
		return fmt.Sprintf("%s: OK", who)
	}
	return ""
}

// MinisNetfsConfigure creates (or replaces) the mount object for id from a
// JSON config. Credentials travel here, in memory; they never reach iSH or
// any file. Does not touch the network. Returns 0 or EINVAL.
//
//export MinisNetfsConfigure
func MinisNetfsConfigure(cfgJSON *C.char) C.int {
	var c netfsConfigJSON
	if err := json.Unmarshal([]byte(C.GoString(cfgJSON)), &c); err != nil || c.ID == "" {
		return netfs.EINVAL
	}
	cfg := c.config()
	cfg.OnTransition = func(name string, from, to netfs.State, st netfs.Status) {
		if line := transitionLine(from, to, st); line != "" {
			netfsEmit(line)
		}
	}
	m, err := netfs.NewMount(cfg)
	if err != nil {
		return netfs.EINVAL
	}
	netfsMu.Lock()
	netfsByID[c.ID] = m
	netfsMu.Unlock()
	return 0
}

// MinisNetfsAttach binds an iSH mount to a configured mount object. options
// carries "id=<id>" (plus display-only options); it is shown in /proc/mounts,
// so it never holds a secret.
//
//export MinisNetfsAttach
func MinisNetfsAttach(source *C.char, options *C.char, outHandle *C.uint64_t) C.int {
	id := ""
	for _, opt := range strings.Split(C.GoString(options), ",") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(opt), "id="); ok {
			id = v
		}
	}
	netfsMu.Lock()
	defer netfsMu.Unlock()
	if netfsByID[id] == nil {
		return netfs.ENOTCONN
	}
	h := netfsNext
	netfsNext++
	netfsHandles[h] = id
	*outHandle = C.uint64_t(h)
	return 0
}

//export MinisNetfsDetach
func MinisNetfsDetach(handle C.uint64_t) {
	netfsMu.Lock()
	delete(netfsHandles, uint64(handle))
	netfsMu.Unlock()
}

func netfsMount(handle C.uint64_t) *netfs.Mount {
	netfsMu.Lock()
	defer netfsMu.Unlock()
	id, ok := netfsHandles[uint64(handle)]
	if !ok {
		return nil
	}
	return netfsByID[id]
}

func netfsMountByID(id *C.char) *netfs.Mount {
	netfsMu.Lock()
	defer netfsMu.Unlock()
	return netfsByID[C.GoString(id)]
}

// MARK: - Cancellation

// Calls are keyed by iSH's call id. A cancel can race the call's start (the
// signal lands between iSH publishing the id and this side registering it),
// so an unknown id leaves a short-lived tombstone that the call then finds.
var (
	callsMu    sync.Mutex
	calls      = map[uint64]chan struct{}{}
	tombstones = map[uint64]time.Time{}
)

func callBegin(id uint64) chan struct{} {
	ch := make(chan struct{})
	callsMu.Lock()
	defer callsMu.Unlock()
	if _, dead := tombstones[id]; dead {
		delete(tombstones, id)
		close(ch)
	}
	calls[id] = ch
	return ch
}

func callEnd(id uint64) {
	callsMu.Lock()
	delete(calls, id)
	callsMu.Unlock()
}

// MinisNetfsCancel asks call to return EINTR. Never blocks.
//
//export MinisNetfsCancel
func MinisNetfsCancel(call C.uint64_t) {
	id := uint64(call)
	callsMu.Lock()
	defer callsMu.Unlock()
	if ch, ok := calls[id]; ok {
		select {
		case <-ch:
		default:
			close(ch)
		}
		return
	}
	now := time.Now()
	for k, t := range tombstones {
		if now.Sub(t) > 10*time.Second {
			delete(tombstones, k)
		}
	}
	tombstones[id] = now
}

func errnoOf(e *netfs.Error) C.int {
	if e == nil {
		return 0
	}
	return C.int(e.Errno)
}

// MARK: - Operations

//export MinisNetfsStat
func MinisNetfsStat(handle C.uint64_t, path *C.char, call C.uint64_t, key C.uint64_t,
	size *C.uint64_t, mtimeSec *C.int64_t, mtimeNsec *C.int32_t, isDir *C.int32_t) C.int {
	m := netfsMount(handle)
	if m == nil {
		return netfs.ENOTCONN
	}
	cancel := callBegin(uint64(call))
	defer callEnd(uint64(call))
	ent, e := m.Stat(C.GoString(path), uint64(key), cancel)
	if e != nil {
		return errnoOf(e)
	}
	*size = C.uint64_t(ent.Size)
	*mtimeSec = C.int64_t(ent.ModTime.Unix())
	*mtimeNsec = C.int32_t(ent.ModTime.Nanosecond())
	*isDir = 0
	if ent.IsDir {
		*isDir = 1
	}
	return 0
}

// MinisNetfsReadDir returns a malloc'd array; release it with
// MinisNetfsFreeDirents.
//
//export MinisNetfsReadDir
func MinisNetfsReadDir(handle C.uint64_t, path *C.char, call C.uint64_t, key C.uint64_t,
	out **C.minis_netfs_dirent, count *C.size_t) C.int {
	m := netfsMount(handle)
	if m == nil {
		return netfs.ENOTCONN
	}
	cancel := callBegin(uint64(call))
	defer callEnd(uint64(call))
	entries, e := m.ReadDir(C.GoString(path), uint64(key), cancel)
	if e != nil {
		return errnoOf(e)
	}
	n := len(entries)
	alloc := n
	if alloc == 0 {
		alloc = 1
	}
	arr := (*C.minis_netfs_dirent)(C.calloc(C.size_t(alloc), C.size_t(unsafe.Sizeof(C.minis_netfs_dirent{}))))
	if arr == nil {
		return netfs.EIO
	}
	items := unsafe.Slice(arr, alloc)
	for i, ent := range entries {
		name := ent.Name
		if len(name) > 255 {
			name = name[:255]
		}
		dst := unsafe.Slice((*byte)(unsafe.Pointer(&items[i].name[0])), 256)
		copy(dst, name)
		dst[len(name)] = 0
		items[i].size = C.uint64_t(ent.Size)
		items[i].mtime_sec = C.int64_t(ent.ModTime.Unix())
		items[i].mtime_nsec = C.int32_t(ent.ModTime.Nanosecond())
		if ent.IsDir {
			items[i].is_dir = 1
		}
	}
	*out = arr
	*count = C.size_t(n)
	return 0
}

//export MinisNetfsFreeDirents
func MinisNetfsFreeDirents(arr *C.minis_netfs_dirent) {
	C.free(unsafe.Pointer(arr))
}

// MinisNetfsRead reads at most one block; *outN may be short.
//
//export MinisNetfsRead
func MinisNetfsRead(handle C.uint64_t, path *C.char, offset C.uint64_t, buf unsafe.Pointer, length C.size_t,
	call C.uint64_t, key C.uint64_t, outN *C.size_t) C.int {
	m := netfsMount(handle)
	if m == nil {
		return netfs.ENOTCONN
	}
	cancel := callBegin(uint64(call))
	defer callEnd(uint64(call))
	// Read into Go memory first; the C buffer is written only on success,
	// right before returning, never after a cancel.
	tmp := make([]byte, int(length))
	n, e := m.ReadAt(C.GoString(path), int64(offset), tmp, uint64(key), cancel)
	if e != nil {
		return errnoOf(e)
	}
	copy(unsafe.Slice((*byte)(buf), int(length)), tmp[:n])
	*outN = C.size_t(n)
	return 0
}

// MinisNetfsStatus writes /proc/fs/netfs/<name> text. Never blocks.
//
//export MinisNetfsStatus
func MinisNetfsStatus(handle C.uint64_t, buf *C.char, size C.size_t) C.int {
	m := netfsMount(handle)
	if m == nil {
		return netfs.ENOTCONN
	}
	text := statusText(m.Status())
	b := unsafe.Slice((*byte)(unsafe.Pointer(buf)), int(size))
	n := copy(b[:len(b)-1], text)
	b[n] = 0
	return 0
}

func statusText(st netfs.Status) string {
	ts := func(t time.Time) string {
		if t.IsZero() {
			return "-"
		}
		return t.UTC().Format(time.RFC3339)
	}
	retry := "-"
	if st.State == netfs.StateOffline {
		retry = ts(st.RetryAt)
	}
	lastErr := st.LastError
	if lastErr == "" {
		lastErr = "-"
	}
	return fmt.Sprintf("name: %s\ntype: %s\nserver: %s\nstate: %s\nsince: %s\nlast_error: %s\nlast_cause: %s\nretry_at: %s\n"+
		"consecutive_failures: %d\ncache_bytes: %d\nin_flight: %d\n"+
		"ops: stat=%d readdir=%d read=%d timeouts=%d fast_fails=%d stale_served=%d\n",
		st.Name, st.Type, st.Server, st.State, ts(st.Since), lastErr, st.LastCause, retry,
		st.ConsecutiveFailures, st.CacheBytes, st.InFlight,
		st.Ops.Stat, st.Ops.ReadDir, st.Ops.Read, st.Ops.Timeouts, st.Ops.FastFails, st.Ops.StaleServed)
}

// MinisNetfsKick lets an offline mount probe at once (network back).
//
//export MinisNetfsKick
func MinisNetfsKick(id *C.char) {
	netfsMu.Lock()
	m := netfsByID[C.GoString(id)]
	netfsMu.Unlock()
	if m != nil {
		m.Kick()
	}
}

// MinisNetfsResetBudget starts a new tool call's budget for key.
//
//export MinisNetfsResetBudget
func MinisNetfsResetBudget(key C.uint64_t) {
	netfsMu.Lock()
	ms := make([]*netfs.Mount, 0, len(netfsByID))
	for _, m := range netfsByID {
		ms = append(ms, m)
	}
	netfsMu.Unlock()
	for _, m := range ms {
		m.ResetBudget(uint64(key))
	}
}

// MARK: - App-side access (Settings, file tools, Browse Files)
//
// The app reads network mounts directly, not through iSH: same mount object,
// same caches and breaker as the guest's netfs (design §3). These answer in
// JSON so the Swift side needs no C structs. Strings returned are malloc'ed;
// free them with MinisNetfsFreeString. Budget key 0: no per-command budget
// (the app lists one directory or reads one file per action).

func cJSON(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		b = []byte(`{"errno":5}`)
	}
	return C.CString(string(b))
}

type entryJSON struct {
	Name  string `json:"name"`
	IsDir bool   `json:"isDir"`
	Size  int64  `json:"size"`
	Mtime int64  `json:"mtime"`
}

type errJSON struct {
	Errno   int    `json:"errno"`
	Cause   string `json:"cause,omitempty"`
	Message string `json:"message,omitempty"`
}

func errOf(e *netfs.Error) errJSON {
	return errJSON{Errno: e.Errno, Cause: e.Cause.String(), Message: e.Msg}
}

func toEntryJSON(e netfs.Entry) entryJSON {
	return entryJSON{Name: e.Name, IsDir: e.IsDir, Size: e.Size, Mtime: e.ModTime.Unix()}
}

// MinisNetfsFreeString frees a string returned by the functions below.
//
//export MinisNetfsFreeString
func MinisNetfsFreeString(s *C.char) {
	C.free(unsafe.Pointer(s))
}

// MinisNetfsRemove drops the mount object for id (mount deleted). An iSH
// mount still attached to it answers ENOTCONN from then on.
//
//export MinisNetfsRemove
func MinisNetfsRemove(id *C.char) {
	netfsMu.Lock()
	delete(netfsByID, C.GoString(id))
	netfsMu.Unlock()
}

// MinisNetfsListJSON lists a directory: {"errno":0,"entries":[…]} or an error.
//
//export MinisNetfsListJSON
func MinisNetfsListJSON(id *C.char, path *C.char) *C.char {
	m := netfsMountByID(id)
	if m == nil {
		return cJSON(errJSON{Errno: netfs.ENOTCONN, Message: "network mount not connected"})
	}
	entries, e := m.ReadDir(C.GoString(path), 0, nil)
	if e != nil {
		return cJSON(errOf(e))
	}
	out := make([]entryJSON, len(entries))
	for i, ent := range entries {
		out[i] = toEntryJSON(ent)
	}
	return cJSON(struct {
		Errno   int         `json:"errno"`
		Entries []entryJSON `json:"entries"`
	}{0, out})
}

// MinisNetfsStatJSON: {"errno":0,"entry":{…}} or an error.
//
//export MinisNetfsStatJSON
func MinisNetfsStatJSON(id *C.char, path *C.char) *C.char {
	m := netfsMountByID(id)
	if m == nil {
		return cJSON(errJSON{Errno: netfs.ENOTCONN, Message: "network mount not connected"})
	}
	ent, e := m.Stat(C.GoString(path), 0, nil)
	if e != nil {
		return cJSON(errOf(e))
	}
	return cJSON(struct {
		Errno int       `json:"errno"`
		Entry entryJSON `json:"entry"`
	}{0, toEntryJSON(ent)})
}

// MinisNetfsReadID reads up to length bytes at offset into buf (owned by the
// caller, written only before this returns). Returns 0 or a Linux errno;
// *outN = bytes read, 0 at end of file. May return fewer bytes than asked
// (one block per call), like read(2).
//
//export MinisNetfsReadID
func MinisNetfsReadID(id *C.char, path *C.char, offset C.uint64_t, buf unsafe.Pointer, length C.size_t,
	outN *C.size_t) C.int {
	*outN = 0
	m := netfsMountByID(id)
	if m == nil {
		return netfs.ENOTCONN
	}
	tmp := make([]byte, int(length))
	n, e := m.ReadAt(C.GoString(path), int64(offset), tmp, 0, nil)
	if e != nil {
		return errnoOf(e)
	}
	copy(unsafe.Slice((*byte)(buf), int(length)), tmp[:n])
	*outN = C.size_t(n)
	return 0
}

type statusJSON struct {
	Name                string `json:"name"`
	Type                string `json:"type"`
	Server              string `json:"server"`
	State               string `json:"state"`
	Since               int64  `json:"since"`
	LastCause           string `json:"lastCause"`
	LastError           string `json:"lastError"`
	RetryAt             int64  `json:"retryAt"`
	ConsecutiveFailures int    `json:"consecutiveFailures"`
	CacheBytes          int64  `json:"cacheBytes"`
}

func unixOrZero(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.Unix()
}

// MinisNetfsStatusJSON is the mount's state for Settings and for the file
// tools' error summaries ({"errno":107} when there is no such mount). Never
// blocks, never touches the network.
//
//export MinisNetfsStatusJSON
func MinisNetfsStatusJSON(id *C.char) *C.char {
	m := netfsMountByID(id)
	if m == nil {
		return cJSON(errJSON{Errno: netfs.ENOTCONN})
	}
	st := m.Status()
	retry := int64(0)
	if st.State == netfs.StateOffline {
		retry = unixOrZero(st.RetryAt)
	}
	return cJSON(statusJSON{
		Name: st.Name, Type: st.Type, Server: st.Server, State: st.State.String(),
		Since: unixOrZero(st.Since), LastCause: st.LastCause.String(), LastError: st.LastError,
		RetryAt: retry, ConsecutiveFailures: st.ConsecutiveFailures, CacheBytes: st.CacheBytes,
	})
}

// MinisNetfsTestJSON is Settings' "Test Connection": connects with the given
// config (same JSON as MinisNetfsConfigure; nothing is stored) and lists the
// root. Blocks up to a metadata deadline; call off the main thread. On a
// certificate failure the result carries the server's certificate, so the
// user can trust it by fingerprint.
//
//export MinisNetfsTestJSON
func MinisNetfsTestJSON(cfgJSON *C.char) *C.char {
	var c netfsConfigJSON
	if err := json.Unmarshal([]byte(C.GoString(cfgJSON)), &c); err != nil {
		return cJSON(netfs.TestResult{Errno: netfs.EINVAL, Message: err.Error()})
	}
	if c.Name == "" {
		c.Name = "test"
	}
	return cJSON(netfs.Test(c.config()))
}
