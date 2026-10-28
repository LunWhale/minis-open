package netfs

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/webdav"
)

// A WebDAV server on a self-signed certificate (httptest's), counting the
// requests that reach the handler — i.e. that got past TLS.
func newTLSServer(t *testing.T) (*httptest.Server, *int64) {
	return newTLSServerWith(t, nil)
}

// freshCert is a self-signed certificate of its own (httptest's servers all
// share one built-in certificate).
func freshCert(t *testing.T) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: "nas.local"},
		NotBefore:    time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

func newTLSServerWith(t *testing.T, cert *tls.Certificate) (*httptest.Server, *int64) {
	t.Helper()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	var reached int64
	h := &webdav.Handler{FileSystem: webdav.Dir(root), LockSystem: webdav.NewMemLS()}
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&reached, 1)
		h.ServeHTTP(w, r)
	}))
	if cert != nil {
		srv.TLS = &tls.Config{Certificates: []tls.Certificate{*cert}}
	}
	srv.StartTLS()
	t.Cleanup(srv.Close)
	return srv, &reached
}

func tlsConfig(url, trusted string) Config {
	return Config{
		Name: "tls", Type: "webdav",
		Params:            map[string]string{"url": url, "vendor": "other", "user": "u", "pass": "secret"},
		TrustedCertSHA256: trusted,
	}
}

func TestSelfSignedRejectedWithoutTrust(t *testing.T) {
	srv, reached := newTLSServer(t)
	r := Test(tlsConfig(srv.URL, ""))
	if r.OK || r.Cause != CauseCert.String() || r.Errno != EACCES {
		t.Fatalf("want a certificate failure, got %+v", r)
	}
	want := Fingerprint(srv.Certificate())
	if r.Cert == nil || r.Cert.SHA256 != want {
		t.Fatalf("want the server's fingerprint %s for the user to confirm, got %+v", want, r.Cert)
	}
	if r.CertChanged {
		t.Fatal("nothing was trusted before: not a change")
	}
	if n := atomic.LoadInt64(reached); n != 0 {
		t.Fatalf("an untrusted server received %d request(s)", n)
	}
}

func TestTrustedFingerprintAccepted(t *testing.T) {
	srv, _ := newTLSServer(t)
	fp := Fingerprint(srv.Certificate())
	// Any common spelling of the fingerprint works.
	spaced := ""
	for i := 0; i < len(fp); i += 2 {
		if i > 0 {
			spaced += ":"
		}
		spaced += fp[i : i+2]
	}
	r := Test(tlsConfig(srv.URL, spaced))
	if !r.OK || r.Entries != 1 {
		t.Fatalf("trusted fingerprint should connect and list a.txt, got %+v", r)
	}
	m, err := NewMount(tlsConfig(srv.URL, fp))
	if err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 16)
	n, e := m.ReadAt("a.txt", 0, buf, 0, nil)
	if e != nil || string(buf[:n]) != "hello" {
		t.Fatalf("read through the pinned mount: %q %v", buf[:n], e)
	}
}

func TestChangedFingerprintRefusedBeforeAnyRequest(t *testing.T) {
	srv, reached := newTLSServer(t)
	stale := "00" + Fingerprint(srv.Certificate())[2:]
	r := Test(tlsConfig(srv.URL, stale))
	if r.OK || r.Cause != CauseCert.String() || !r.CertChanged {
		t.Fatalf("want 'certificate changed', got %+v", r)
	}
	if r.Cert == nil || r.Cert.SHA256 != Fingerprint(srv.Certificate()) {
		t.Fatalf("want the new fingerprint shown, got %+v", r.Cert)
	}
	// The pin closes the connection in GotConn, before the request is
	// written: the credentials never reach a server presenting another key.
	if n := atomic.LoadInt64(reached); n != 0 {
		t.Fatalf("a server with the wrong certificate received %d request(s)", n)
	}
	m, _ := NewMount(tlsConfig(srv.URL, stale))
	if _, e := m.Stat("a.txt", 0, nil); e == nil || e.Cause != CauseCert {
		t.Fatalf("mount op: want a certificate error, got %v", e)
	}
}

func TestPinIsPerMount(t *testing.T) {
	// A mount trusting server A's fingerprint must not make server B (another
	// self-signed certificate) acceptable to a mount that trusts nothing.
	a, _ := newTLSServer(t)
	bc := freshCert(t)
	b, _ := newTLSServerWith(t, &bc)
	if r := Test(tlsConfig(a.URL, Fingerprint(a.Certificate()))); !r.OK {
		t.Fatalf("A pinned: %+v", r)
	}
	if r := Test(tlsConfig(b.URL, "")); r.OK || r.Cause != CauseCert.String() {
		t.Fatalf("B unpinned must still be refused: %+v", r)
	}
	if r := Test(tlsConfig(b.URL, Fingerprint(a.Certificate()))); r.OK {
		t.Fatalf("B with A's fingerprint must be refused: %+v", r)
	}
}
