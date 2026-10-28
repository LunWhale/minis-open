package netfs

import (
	"time"
)

// TestResult is what the settings page's "Test Connection" shows.
type TestResult struct {
	OK      bool   `json:"ok"`
	Errno   int    `json:"errno,omitempty"`
	Cause   string `json:"cause,omitempty"`
	Message string `json:"message,omitempty"`
	Entries int    `json:"entries"`
	// Cert is set on a certificate failure, so the user can decide whether to
	// trust this server by its fingerprint (design §10, Q8). CertChanged: a
	// fingerprint was already trusted and the server now presents another.
	Cert        *CertInfo `json:"cert,omitempty"`
	CertChanged bool      `json:"certChanged,omitempty"`
}

// Test connects with cfg and lists the mount's root once. It uses a fresh
// mount object (no cache, no breaker history), so it says how the server
// answers now, not what an existing mount remembers.
func Test(cfg Config) TestResult {
	cfg.CacheDir = ""
	cfg.OnTransition = nil
	// One honest attempt, not the offline threshold's worth of them.
	cfg.FailThreshold = 1
	cfg.TimeoutThreshold = 1
	m, err := NewMount(cfg)
	if err != nil {
		return TestResult{Errno: EINVAL, Cause: CauseOther.String(), Message: err.Error()}
	}
	entries, e := m.ReadDir("", 0, nil)
	if e == nil {
		return TestResult{OK: true, Entries: len(entries)}
	}
	r := TestResult{Errno: e.Errno, Cause: e.Cause.String(), Message: e.Msg}
	if e.Cause == CauseCert {
		for _, k := range []string{"url", "endpoint"} {
			if raw := cfg.Params[k]; raw != "" {
				if info, ferr := FetchCert(raw, 5*time.Second); ferr == nil {
					r.Cert = info
					r.CertChanged = cfg.TrustedCertSHA256 != "" && NormalizeFingerprint(cfg.TrustedCertSHA256) != info.SHA256
				}
				break
			}
		}
	}
	return r
}
