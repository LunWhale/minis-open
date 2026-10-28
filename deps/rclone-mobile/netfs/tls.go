package netfs

// Self-signed certificates trusted by fingerprint (design §10, Q8).
//
// rclone builds each backend's HTTP transport itself and offers no per-mount
// TLS hook: its only knobs are the global-style InsecureSkipVerify and CA
// files, and a CA file still requires the host name to match, which a NAS's
// self-signed certificate usually does not. So a mount with a trusted
// fingerprint turns chain verification off for ITS OWN ConfigInfo only and
// checks the fingerprint itself, from an httptrace hook on its context:
// GotConn runs for every request, after the connection is obtained (new or
// reused) and before anything is written on it. A mismatch closes the
// connection there, so no request — and no credential — reaches the server.

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"net"
	"net/http/httptrace"
	"net/url"
	"strings"
	"sync/atomic"
	"time"
)

// Fingerprint is the lowercase hex SHA-256 of a certificate's DER bytes, the
// form the settings page shows and the config stores.
func Fingerprint(cert *x509.Certificate) string {
	sum := sha256.Sum256(cert.Raw)
	return hex.EncodeToString(sum[:])
}

// NormalizeFingerprint accepts "AB:CD:…", "ab cd …" or "abcd…".
func NormalizeFingerprint(s string) string {
	r := strings.NewReplacer(":", "", " ", "", "-", "")
	return strings.ToLower(r.Replace(strings.TrimSpace(s)))
}

// certPin remembers the last fingerprint that did not match, so the failed
// request can be reported as a certificate error rather than a dropped
// connection.
type certPin struct {
	want     string
	mismatch atomic.Value // string: the fingerprint the server presented
}

func (p *certPin) context(ctx context.Context) context.Context {
	return httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{
		GotConn: func(info httptrace.GotConnInfo) {
			tc, ok := info.Conn.(*tls.Conn)
			if !ok {
				return // plain http: nothing to pin
			}
			st := tc.ConnectionState()
			got := ""
			if len(st.PeerCertificates) > 0 {
				got = Fingerprint(st.PeerCertificates[0])
			}
			if got != p.want {
				p.mismatch.Store(got)
				_ = tc.Close()
			}
		},
	})
}

// takeMismatch returns (and clears) a fingerprint seen since the last call.
func (p *certPin) takeMismatch() string {
	if p == nil {
		return ""
	}
	if v, _ := p.mismatch.Swap("").(string); v != "" {
		return v
	}
	return ""
}

// isCertError reports a TLS verification failure of an unpinned mount.
func isCertError(err error) bool {
	var unknown x509.UnknownAuthorityError
	var host x509.HostnameError
	var invalid x509.CertificateInvalidError
	var verify *tls.CertificateVerificationError
	if errors.As(err, &unknown) || errors.As(err, &host) || errors.As(err, &invalid) || errors.As(err, &verify) {
		return true
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "x509:") || strings.Contains(msg, "certificate signed by unknown authority")
}

// CertInfo is what the settings page shows before the user trusts a server.
type CertInfo struct {
	SHA256   string    `json:"sha256"`
	Subject  string    `json:"subject"`
	Issuer   string    `json:"issuer"`
	NotAfter time.Time `json:"notAfter"`
}

// tlsAddress is host:port of an https URL ("" for anything else).
func tlsAddress(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" {
		return ""
	}
	port := u.Port()
	if port == "" {
		port = "443"
	}
	return net.JoinHostPort(u.Hostname(), port)
}

// FetchCert reads the certificate a server presents, without trusting it.
// Used only to show the user what they are about to trust.
func FetchCert(rawURL string, timeout time.Duration) (*CertInfo, error) {
	addr := tlsAddress(rawURL)
	if addr == "" {
		return nil, errors.New("not an https address")
	}
	host, _, _ := net.SplitHostPort(addr)
	d := &net.Dialer{Timeout: timeout}
	conn, err := tls.DialWithDialer(d, "tcp", addr, &tls.Config{InsecureSkipVerify: true, ServerName: host}) //nolint:gosec // inspection only, nothing is sent
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	certs := conn.ConnectionState().PeerCertificates
	if len(certs) == 0 {
		return nil, errors.New("server presented no certificate")
	}
	c := certs[0]
	return &CertInfo{SHA256: Fingerprint(c), Subject: c.Subject.String(), Issuer: c.Issuer.String(), NotAfter: c.NotAfter}, nil
}
