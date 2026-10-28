package rcloneroute

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"strconv"
	"sync"
	"testing"
	"time"

	_ "github.com/rclone/rclone/backend/ftp"
	_ "github.com/rclone/rclone/backend/sftp"
	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/config/configmap"
	"github.com/rclone/rclone/fs/config/obscure"
)

// optionFor reads socks_proxy for a remote the way NewFs does.
func optionFor(t *testing.T, backend string, conn configmap.Simple) (string, bool) {
	t.Helper()
	ri, err := fs.Find(backend)
	if err != nil {
		t.Fatal(err)
	}
	return fs.ConfigMap(ri.Prefix, ri.Options, "", conn).Get("socks_proxy")
}

func TestUnsetIsRcloneAsBefore(t *testing.T) {
	if _, err := SetSocks("", nil); err != nil {
		t.Fatal(err)
	}
	for _, b := range Backends {
		if v, _ := optionFor(t, b, nil); v != "" {
			t.Fatalf("%s socks_proxy = %q before anything was set", b, v)
		}
		ri, _ := fs.Find(b)
		if o := ri.Options.Get("socks_proxy"); o.IsSet() || !o.IsDefault() {
			t.Fatalf("%s option touched while unset", b)
		}
	}
}

func TestSetAppliesToEveryRemoteButNotOverExplicit(t *testing.T) {
	defer SetSocks("", nil)
	changed, err := SetSocks("backup:pw@127.0.0.1:1080", nil)
	if err != nil || !changed {
		t.Fatalf("SetSocks: changed=%v err=%v", changed, err)
	}
	for _, b := range Backends {
		if v, ok := optionFor(t, b, nil); !ok || v != "backup:pw@127.0.0.1:1080" {
			t.Fatalf("%s socks_proxy = %q, %v", b, v, ok)
		}
		if v, _ := optionFor(t, b, configmap.Simple{"socks_proxy": "mine:1"}); v != "mine:1" {
			t.Fatalf("%s: a remote's own socks_proxy must win, got %q", b, v)
		}
	}
	if again, _ := SetSocks("backup:pw@127.0.0.1:1080", nil); again {
		t.Fatal("same value reported as a change")
	}
	if changed, _ := SetSocks("", nil); !changed {
		t.Fatal("clearing not reported")
	}
	for _, b := range Backends {
		ri, _ := fs.Find(b)
		if o := ri.Options.Get("socks_proxy"); o.IsSet() || !o.IsDefault() {
			t.Fatalf("%s not restored after clearing", b)
		}
	}
}

func TestRedact(t *testing.T) {
	if got := Redact("backup:secret@127.0.0.1:5000"); got != "backup:<password>@127.0.0.1:5000" {
		t.Fatal(got)
	}
	if got := Redact("127.0.0.1:5000"); got != "127.0.0.1:5000" {
		t.Fatal(got)
	}
}

// End to end: an SFTP remote created after SetSocks connects through the
// SOCKS5 server, to the address the remote names. The "SSH server" only
// accepts and closes, so NewFs fails - after the connection was made.
func TestSFTPConnectsThroughSocks(t *testing.T) {
	target, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	go func() {
		for {
			c, err := target.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	s := newSocks(t)
	defer SetSocks("", nil)
	if _, err := SetSocks("backup:pw@"+s.ln.Addr().String(), nil); err != nil {
		t.Fatal(err)
	}
	_, port, _ := net.SplitHostPort(target.Addr().String())
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, err = fs.NewFs(ctx, ":sftp,host=127.0.0.1,port="+port+",user=u,pass="+obscure.MustObscure("x")+":")
	t.Logf("NewFs: %v", err)
	if got := s.seen(); len(got) == 0 || got[0] != "backup|127.0.0.1:"+port {
		t.Fatalf("SOCKS server saw %v", got)
	}

	// Cleared: the same remote connects directly again.
	SetSocks("", nil)
	before := len(s.seen())
	_, _ = fs.NewFs(ctx, ":sftp,host=127.0.0.1,port="+port+",user=u,pass="+obscure.MustObscure("x")+":")
	if len(s.seen()) != before {
		t.Fatal("cleared, but SFTP still went through SOCKS")
	}
}

// Minimal SOCKS5 server (username/password auth, CONNECT) that records
// "user|host:port" and relays.
type socks struct {
	ln  net.Listener
	mu  sync.Mutex
	got []string
}

func newSocks(t *testing.T) *socks {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := &socks{ln: ln}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go s.handle(c)
		}
	}()
	return s
}

func (s *socks) seen() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.got...)
}

func (s *socks) handle(c net.Conn) {
	defer c.Close()
	b := make([]byte, 262)
	if _, err := io.ReadFull(c, b[:2]); err != nil {
		return
	}
	io.ReadFull(c, b[:b[1]])
	c.Write([]byte{5, 2}) // username/password
	io.ReadFull(c, b[:2])
	user := make([]byte, b[1])
	io.ReadFull(c, user)
	io.ReadFull(c, b[:1])
	io.ReadFull(c, make([]byte, b[0]))
	c.Write([]byte{1, 0})
	io.ReadFull(c, b[:4])
	var host string
	switch b[3] {
	case 1:
		io.ReadFull(c, b[:4])
		host = net.IP(b[:4]).String()
	case 3:
		io.ReadFull(c, b[:1])
		h := make([]byte, b[0])
		io.ReadFull(c, h)
		host = string(h)
	default:
		return
	}
	io.ReadFull(c, b[:2])
	addr := net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(b[:2]))))
	s.mu.Lock()
	s.got = append(s.got, string(user)+"|"+addr)
	s.mu.Unlock()
	up, err := net.Dial("tcp", addr)
	if err != nil {
		c.Write([]byte{5, 5, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	defer up.Close()
	c.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0})
	go io.Copy(up, c)
	io.Copy(c, up)
}
