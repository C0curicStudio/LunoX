// Package hy2bridge embeds the official Hysteria2 client in the iOS app (built with gomobile into Hy2bridge.xcframework).
// It exposes ONE thing to Swift: a loopback HTTP CONNECT proxy that tunnels every connection through your Hysteria2 server.
// WebKit is pointed at it via WKWebsiteDataStore.proxyConfigurations, so no VPN profile / second app is needed.
package hy2bridge

import (
	"bufio"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/apernet/hysteria/core/v2/client"
	"github.com/apernet/hysteria/extras/v2/obfs"
)

type factory struct{ psk []byte }

func (f *factory) New(net.Addr) (net.PacketConn, error) {
	pc, err := net.ListenUDP("udp", nil)
	if err != nil {
		return nil, err
	}
	if len(f.psk) == 0 {
		return pc, nil
	}
	return obfs.WrapPacketConnSalamander(pc, f.psk)
}

var (
	mu       sync.Mutex
	listener net.Listener
	hy       client.Client
	status   = "stopped"
	connects int
)

func setStatus(s string) { mu.Lock(); status = s; mu.Unlock() }

// Status returns "stopped", "idle", "connected" or "error: ...".
func Status() string { mu.Lock(); defer mu.Unlock(); return status }

// Start connects lazily to a Hysteria2 server and starts the loopback proxy. It returns the loopback port.
// obfsPassword may be empty (no obfuscation). pinSHA256 (hex) pins the server certificate; if empty the normal
// verification applies unless insecure is true. downMbps is the downstream bandwidth hint (0 = unknown).
// token protects the loopback proxy: clients must send Proxy-Authorization: Basic base64("lunox:"+token).
func Start(host string, port int, auth string, obfsPassword string, sni string, insecure bool, pinSHA256 string, downMbps int, token string) (int, error) {
	Stop()
	if host == "" || port <= 0 || port > 65535 || auth == "" || token == "" {
		return 0, errors.New("invalid hysteria2 parameters")
	}
	pin := strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(pinSHA256, ":", ""), " ", ""))

	cfgFn := func() (*client.Config, error) {
		addr, err := net.ResolveUDPAddr("udp", net.JoinHostPort(host, strconv.Itoa(port)))
		if err != nil {
			return nil, err
		}
		tc := client.TLSConfig{ServerName: sni, InsecureSkipVerify: insecure}
		if tc.ServerName == "" {
			tc.ServerName = host
		}
		if pin != "" {
			tc.InsecureSkipVerify = true // we verify the pin ourselves
			tc.VerifyPeerCertificate = func(raw [][]byte, _ [][]*x509.Certificate) error {
				if len(raw) == 0 {
					return errors.New("no certificate")
				}
				sum := sha256.Sum256(raw[0])
				if hex.EncodeToString(sum[:]) != pin {
					return errors.New("hysteria2 certificate pin mismatch")
				}
				return nil
			}
		}
		cfg := &client.Config{
			ConnFactory: &factory{psk: []byte(obfsPassword)},
			ServerAddr:  addr,
			Auth:        auth,
			TLSConfig:   tc,
			FastOpen:    true, // TCP() returns at once instead of waiting a round trip for the server's answer: every new connection of a page starts one RTT sooner
		}
		if downMbps > 0 {
			cfg.BandwidthConfig = client.BandwidthConfig{MaxRx: uint64(downMbps) * 125000}
		}
		return cfg, nil
	}
	c, err := client.NewReconnectableClient(cfgFn, func(_ client.Client, _ *client.HandshakeInfo, n int) {
		mu.Lock()
		connects = n
		status = "connected"
		mu.Unlock()
	}, true)
	if err != nil {
		return 0, err
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		_ = c.Close()
		return 0, err
	}
	mu.Lock()
	hy, listener, status = c, ln, "idle"
	mu.Unlock()
	go serve(ln, c, token)
	go Warm() // set the QUIC connection up now, not on the first tap
	return ln.Addr().(*net.TCPAddr).Port, nil
}

// Warm opens (and drops) one tunnelled connection so the QUIC session is ready before the page asks for it.
// Called at start and whenever the app returns to the foreground.
func Warm() {
	mu.Lock()
	c := hy
	mu.Unlock()
	if c == nil {
		return
	}
	if conn, err := dial(c, "cp.cloudflare.com:80"); err == nil {
		_ = conn.Close()
	}
}

// Stop closes the proxy and the Hysteria2 connection.
func Stop() {
	mu.Lock()
	ln, c := listener, hy
	listener, hy, status = nil, nil, "stopped"
	mu.Unlock()
	if ln != nil {
		_ = ln.Close()
	}
	if c != nil {
		_ = c.Close()
	}
}

// dial opens a tunnelled TCP connection. After the network changed or the phone slept, the first call on a dead QUIC
// connection fails and only marks it dead; the retry then reconnects. Hide that first failure from the caller.
func dial(c client.Client, addr string) (net.Conn, error) {
	conn, err := c.TCP(addr)
	if err != nil {
		time.Sleep(200 * time.Millisecond)
		conn, err = c.TCP(addr)
	}
	return conn, err
}

// Probe opens one tunnelled TCP connection to addr ("host:port") to prove the Hysteria2 link works. Returns millis.
func Probe(addr string) (int, error) {
	mu.Lock()
	c := hy
	mu.Unlock()
	if c == nil {
		return 0, errors.New("hysteria2 not started")
	}
	t0 := time.Now()
	conn, err := dial(c, addr)
	if err != nil {
		setStatus("error: " + err.Error())
		return 0, err
	}
	_ = conn.Close()
	return int(time.Since(t0).Milliseconds()), nil
}

func serve(ln net.Listener, c client.Client, token string) {
	want := "Basic " + base64.StdEncoding.EncodeToString([]byte("lunox:"+token))
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go handle(conn, c, want)
	}
}

func reply(w io.Writer, line string) {
	_, _ = fmt.Fprintf(w, "HTTP/1.1 %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", line)
}

func handle(conn net.Conn, c client.Client, want string) {
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(15 * time.Second))
	br := bufio.NewReaderSize(conn, 16*1024)
	first, err := br.ReadString('\n')
	if err != nil {
		return
	}
	parts := strings.Fields(first)
	authed := false
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			return
		}
		line = strings.TrimSpace(line)
		if line == "" {
			break
		}
		if i := strings.IndexByte(line, ':'); i > 0 && strings.EqualFold(line[:i], "proxy-authorization") && strings.TrimSpace(line[i+1:]) == want {
			authed = true
		}
	}
	if len(parts) < 2 || !strings.EqualFold(parts[0], "CONNECT") {
		reply(conn, "405 Method Not Allowed")
		return
	}
	if !authed {
		_, _ = io.WriteString(conn, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"lunox\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
		return
	}
	_ = conn.SetReadDeadline(time.Time{})
	remote, err := dial(c, parts[1])
	if err != nil {
		setStatus("error: " + err.Error())
		reply(conn, "502 Bad Gateway")
		return
	}
	defer remote.Close()
	_, _ = io.WriteString(conn, "HTTP/1.1 200 Connection Established\r\n\r\n")
	done := make(chan struct{}, 2)
	go func() { // anything WebKit already sent after the CONNECT head
		if n := br.Buffered(); n > 0 {
			b, _ := br.Peek(n)
			_, _ = remote.Write(b)
		}
		_, _ = io.Copy(remote, conn)
		done <- struct{}{}
	}()
	go func() { _, _ = io.Copy(conn, remote); done <- struct{}{} }()
	<-done
}
