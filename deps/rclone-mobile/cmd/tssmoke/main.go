// Command tssmoke is a host-side (macOS) smoke test for the PoC tsnet wrapper:
// start without an auth key, read the status, open the SOCKS5 proxy, and
// check that it rejects bad credentials and dials through the tailnet with
// good ones. It never logs in, so the dial is expected to fail with a
// tailnet error rather than a SOCKS error.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"time"

	"golang.org/x/net/proxy"

	"github.com/OpenMinis/minis-rclone/tsnet"
)

func main() {
	dir := os.Args[1]
	if err := tsnet.Start("", "minis-poc-smoke", dir); err != nil {
		fmt.Println("START FAIL:", err)
		os.Exit(1)
	}
	defer tsnet.Stop()
	fmt.Println("start: ok")

	var st map[string]any
	for i := 0; i < 20; i++ {
		json.Unmarshal([]byte(tsnet.StatusJSON()), &st)
		if st["authURL"] != nil || st["backendState"] == "Running" {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if u, ok := st["authURL"].(string); ok && len(u) > 30 {
		st["authURL"] = u[:30] + "…"
	}
	b, _ := json.Marshal(st)
	fmt.Println("status:", string(b))

	credsJSON, err := tsnet.ListenSocks("127.0.0.1:0")
	if err != nil {
		fmt.Println("SOCKS FAIL:", err)
		os.Exit(1)
	}
	var creds struct{ Addr, Username, Password string }
	json.Unmarshal([]byte(credsJSON), &creds)
	fmt.Println("socks: listening on", creds.Addr, "user", creds.Username)

	try := func(label, user, pass string) {
		d, _ := proxy.SOCKS5("tcp", creds.Addr, &proxy.Auth{User: user, Password: pass}, proxy.Direct)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		c, err := d.(proxy.ContextDialer).DialContext(ctx, "tcp", "100.100.100.100:80")
		if c != nil {
			c.Close()
		}
		fmt.Printf("socks %s: err=%v\n", label, err)
	}
	try("wrong password", creds.Username, "nope")
	try("right password", creds.Username, creds.Password)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := tsnet.Dial(ctx, "tcp", "100.100.100.100:80")
	if c != nil {
		c.Close()
	}
	fmt.Println("direct Dial (not logged in, expected to fail cleanly):", err)
	var _ net.Conn
}
