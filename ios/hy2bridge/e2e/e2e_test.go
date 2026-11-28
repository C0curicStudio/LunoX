package e2e

// End-to-end test: real Hysteria2 server (core library) with Salamander obfuscation + certificate pinning,
// the hy2bridge loopback proxy in front of it, and a plain TCP echo server behind it.

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"io"
	"math/big"
	"net"
	"strings"
	"testing"
	"time"

	"hy2bridge"

	"github.com/apernet/hysteria/core/v2/server"
	"github.com/apernet/hysteria/extras/v2/obfs"
)

type auth struct{ pw string }

func (a auth) Authenticate(_ net.Addr, p string, _ uint64) (bool, string) { return p == a.pw, "u" }

type out struct{}

func (out) TCP(_ *server.RequestInfo, addr string) (net.Conn, error) { return net.Dial("tcp", addr) }
func (out) UDP(_ *server.RequestInfo, _ string) (server.UDPConn, error) { return nil, io.EOF }
func (out) CheckUDP(_ *server.RequestInfo, _ string) error             { return io.EOF }

func selfSigned(t *testing.T) (tls.Certificate, string) {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "hy2.test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), DNSNames: []string{"hy2.test"}}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(der)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: k}, hex.EncodeToString(sum[:])
}

func TestEndToEnd(t *testing.T) {
	// echo server (the "website")
	echo, _ := net.Listen("tcp", "127.0.0.1:0")
	go func() {
		for {
			c, err := echo.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); _, _ = io.Copy(c, c) }()
		}
	}()

	cert, pin := selfSigned(t)
	udp, _ := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	pc, _ := obfs.WrapPacketConnSalamander(udp, []byte("obfs-secret"))
	srv, err := server.NewServer(&server.Config{TLSConfig: server.TLSConfig{Certificates: []tls.Certificate{cert}}, Conn: pc, Authenticator: auth{"hy2-password"}, Outbound: out{}})
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = srv.Serve() }()
	defer srv.Close()
	hp := udp.LocalAddr().(*net.UDPAddr).Port

	// good credentials + correct pin + obfs
	port, err := hy2bridge.Start("127.0.0.1", hp, "hy2-password", "obfs-secret", "hy2.test", false, pin, 50, "tok")
	if err != nil {
		t.Fatal(err)
	}
	defer hy2bridge.Stop()

	connect := func(authHdr string) (net.Conn, string) {
		c, err := net.Dial("tcp", net.JoinHostPort("127.0.0.1", itoa(port)))
		if err != nil {
			t.Fatal(err)
		}
		req := "CONNECT " + echo.Addr().String() + " HTTP/1.1\r\nHost: x\r\n" + authHdr + "\r\n"
		_, _ = io.WriteString(c, req)
		buf := make([]byte, 64)
		_ = c.SetReadDeadline(time.Now().Add(8 * time.Second))
		n, _ := c.Read(buf)
		return c, string(buf[:n])
	}

	// 1) no proxy auth -> 407 (other apps on the phone cannot borrow the tunnel)
	if c, resp := connect(""); !strings.HasPrefix(resp, "HTTP/1.1 407") {
		t.Fatalf("expected 407, got %q", resp)
	} else {
		c.Close()
	}

	// 2) authenticated CONNECT through Hysteria2 to the echo server
	c, resp := connect("Proxy-Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte("lunox:tok")) + "\r\n")
	if !strings.HasPrefix(resp, "HTTP/1.1 200") {
		t.Fatalf("tunnel not established: %q (status %s)", resp, hy2bridge.Status())
	}
	_, _ = io.WriteString(c, "hello-through-hysteria2")
	got := make([]byte, 23)
	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(c, got); err != nil || string(got) != "hello-through-hysteria2" {
		t.Fatalf("echo mismatch: %q err=%v", got, err)
	}
	c.Close()
	if hy2bridge.Status() != "connected" {
		t.Fatalf("status %s", hy2bridge.Status())
	}
	if ms, err := hy2bridge.Probe(echo.Addr().String()); err != nil || ms < 0 {
		t.Fatalf("probe: %v", err)
	}

	// 3) wrong certificate pin must be refused (no tunnel)
	hy2bridge.Stop()
	port, err = hy2bridge.Start("127.0.0.1", hp, "hy2-password", "obfs-secret", "hy2.test", false, strings.Repeat("0", 64), 0, "tok")
	if err != nil {
		t.Fatal(err)
	}
	c, resp = connect("Proxy-Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte("lunox:tok")) + "\r\n")
	if strings.HasPrefix(resp, "HTTP/1.1 200") {
		t.Fatalf("wrong pin must not connect, got %q", resp)
	}
	c.Close()
}

func itoa(i int) string { return big.NewInt(int64(i)).String() }
