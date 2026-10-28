// Package rcloneroute points rclone's SFTP and FTP backends at the app's
// local SOCKS5 entry, so backups and network mounts to those servers follow
// the backup scope of Settings > Network (direct, the tailnet, or a proxy).
//
// rclone's --http-proxy, which the app already sets for the scope, only
// reaches backends built on an http.Transport (WebDAV, S3, cloud drives).
// SFTP and FTP dial through rclone's own dialer, but both have a
// `socks_proxy` option; this sets it the way a command-line flag would
// (`--sftp-socks-proxy`): it applies to every remote of that backend unless
// the remote names its own, and it overrides nothing the user configured.
// SMB has no such option and is not covered here.
//
// A remote rclone has already built keeps its connections, so a change
// clears rclone's fs cache: the next use rebuilds the remote with the new
// route. "" restores rclone's own behaviour exactly (the option is unset,
// not set to empty).
package rcloneroute

import (
	"fmt"
	"strings"
	"sync"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/cache"
)

// Backends that read `socks_proxy`.
var Backends = []string{"sftp", "ftp"}

var (
	mu      sync.Mutex
	current string
)

// SetSocks routes SFTP and FTP through socks ("user:pass@host:port", the
// format rclone's option takes) or, with "", leaves them direct. It reports
// whether anything changed. logf may be nil.
func SetSocks(socks string, logf func(string, ...any)) (bool, error) {
	mu.Lock()
	defer mu.Unlock()
	if socks == current {
		return false, nil
	}
	for _, name := range Backends {
		ri, err := fs.Find(name)
		if err != nil {
			return false, fmt.Errorf("rcloneroute: backend %s not linked: %w", name, err)
		}
		opt := ri.Options.Get("socks_proxy")
		if opt == nil {
			return false, fmt.Errorf("rcloneroute: %s has no socks_proxy option", name)
		}
		if socks == "" {
			opt.Value = opt.Default
			opt.MarkUnset()
		} else if err := opt.Set(socks); err != nil {
			return false, fmt.Errorf("rcloneroute: %s socks_proxy: %w", name, err)
		}
	}
	current = socks
	// Remotes built for the old route would keep using it until they expire.
	cache.Clear()
	if logf != nil {
		if socks == "" {
			logf("[Net][Backup] rclone SFTP/FTP: direct (socks_proxy unset); fs cache cleared")
		} else {
			logf("[Net][Backup] rclone SFTP/FTP → socks5://%s; fs cache cleared", Redact(socks))
		}
	}
	return true, nil
}

// Current is the value last set, "" when SFTP/FTP connect directly.
func Current() string {
	mu.Lock()
	defer mu.Unlock()
	return current
}

// Redact hides the password of "user:pass@host:port".
func Redact(socks string) string {
	at := strings.LastIndex(socks, "@")
	if at < 0 {
		return socks
	}
	creds := socks[:at]
	if c := strings.Index(creds, ":"); c >= 0 {
		creds = creds[:c] + ":<password>"
	}
	return creds + socks[at:]
}
