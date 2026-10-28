package gomobile

import (
	"github.com/OpenMinis/minis-rclone/rcloneroute"
	"github.com/OpenMinis/minis-rclone/tsnet"
)

// RcloneSetSocks sets socks_proxy ("user:pass@host:port") for every SFTP and
// FTP remote created from now on, or unsets it with "", so they follow the
// backup scope through the local SOCKS5 entry. A change clears rclone's fs
// cache. Returns {"ok":true,"result":{"changed":b}} or {"ok":false,...}.
func RcloneSetSocks(socks string) string {
	changed, err := rcloneroute.SetSocks(socks, tsnet.Logf)
	return envelope(marshal(map[string]bool{"changed": changed}), err)
}
