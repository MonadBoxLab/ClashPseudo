//go:build linux && !android

package engine

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	clock "github.com/metacubex/mihomo/ntp"
	tun "github.com/metacubex/sing-tun"
	D "github.com/miekg/dns"
)

func ingressPort(t *testing.T) int {
	t.Helper()
	for i := 0; i < 20; i++ {
		tcp, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		port := tcp.Addr().(*net.TCPAddr).Port
		udp, err := net.ListenPacket("udp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
		_ = tcp.Close()
		if err == nil {
			_ = udp.Close()
			return port
		}
	}
	t.Fatal("could not reserve a TCP/UDP test port")
	return 0
}

func attachIngressFixture(t *testing.T, e *Engine) error {
	t.Helper()
	fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	device := &ownedTestTun{fd: fd, replacement: -1}
	t.Cleanup(func() {
		if device.replacement >= 0 {
			_ = syscall.Close(device.replacement)
		}
	})
	return e.attach(fd, 1, tunFactories{func(tun.Options) (tun.Tun, error) { return device, nil }, func(string, tun.StackOptions) (tun.Stack, error) { return &ownedTestStack{}, nil }})
}

func assertIngressBindable(t *testing.T, port int) {
	t.Helper()
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	tcp, err := net.Listen("tcp4", address)
	if err != nil {
		t.Fatalf("TCP %s was not released: %v", address, err)
	}
	_ = tcp.Close()
	udp, err := net.ListenPacket("udp4", address)
	if err != nil {
		t.Fatalf("UDP %s was not released: %v", address, err)
	}
	_ = udp.Close()
}

func ingressCertificate(t *testing.T, home string) (*x509.CertPool, string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "ingress.test"}, DNSNames: []string{"ingress.test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	certificate, privateKey := filepath.Join(home, "listener.crt"), filepath.Join(home, "listener.key")
	if err := os.WriteFile(certificate, certPEM, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(privateKey, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0600); err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(certPEM) {
		t.Fatal("invalid generated test certificate")
	}
	return roots, certificate, privateKey
}

func TestIngressPreviewDoesNotBindAndAttachedListenersServeTLSAndDNSAndReleasePorts(t *testing.T) {
	home := t.TempDir()
	roots, certificate, privateKey := ingressCertificate(t, home)
	httpPort, socksPort, mixedPort, tlsPort, tunnelPort, dnsPort := ingressPort(t), ingressPort(t), ingressPort(t), ingressPort(t), ingressPort(t), ingressPort(t)
	body := fmt.Sprintf(`ipv6: false
port: %d
socks-port: %d
mixed-port: %d
hosts: {ingress.test: 192.0.2.77}
dns: {listen: '127.0.0.1:%d', enhanced-mode: redir-host}
listeners:
  - {name: secure, type: http, listen: 127.0.0.1, port: %d, certificate: %q, private-key: %q}
tunnels:
  - {network: [tcp, udp], address: '127.0.0.1:%d', target: '127.0.0.1:9', proxy: DIRECT}
rules: ['MATCH,DIRECT']
`, httpPort, socksPort, mixedPort, dnsPort, tlsPort, certificate, privateKey, tunnelPort)
	ports := []int{httpPort, socksPort, mixedPort, tlsPort, tunnelPort, dnsPort}
	var e Engine
	if err := e.Prepare(home, []byte(body), "", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	for _, port := range ports {
		assertIngressBindable(t, port)
	}
	requireStop(t, &e)
	if err := e.PrepareWithOptions(home, []byte(body), "", nil, func(int) bool { return true }, PrepareOptions{Purpose: "VPN", Generation: 7, Composition: "ingress"}); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	// Preparation leaves external traffic admission closed until TUN handoff.
	for _, port := range ports {
		assertIngressBindable(t, port)
	}
	if err := attachIngressFixture(t, &e); err != nil {
		t.Fatal(err)
	}
	for _, port := range ports {
		conn, err := net.DialTimeout("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), time.Second)
		if err != nil {
			t.Fatalf("attached ingress %d not listening: %v", port, err)
		}
		_ = conn.Close()
	}
	secure, err := tls.DialWithDialer(&net.Dialer{Timeout: time.Second}, "tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(tlsPort)), &tls.Config{RootCAs: roots, ServerName: "ingress.test", MinVersion: tls.VersionTLS12})
	if err != nil {
		t.Fatalf("configured public TLS listener did not handshake: %v", err)
	}
	_ = secure.Close()
	question := new(D.Msg)
	question.SetQuestion("ingress.test.", D.TypeA)
	for _, network := range []string{"udp", "tcp"} {
		client := &D.Client{Net: network, Timeout: time.Second}
		answer, _, err := client.Exchange(question, net.JoinHostPort("127.0.0.1", strconv.Itoa(dnsPort)))
		if err != nil || len(answer.Answer) != 1 || !strings.Contains(answer.Answer[0].String(), "192.0.2.77") {
			t.Fatalf("configured %s DNS service did not answer from actual resolver: %+v %v", network, answer, err)
		}
	}
	requireStop(t, &e)
	for _, port := range ports {
		assertIngressBindable(t, port)
	}
}

func TestIngressBindFailureRollsBackEarlierListenersAndTUN(t *testing.T) {
	first, second := ingressPort(t), ingressPort(t)
	occupied, err := net.ListenPacket("udp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(second)))
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	var e Engine
	prepareVPN(t, &e, fmt.Sprintf("ipv6: false\nport: %d\nsocks-port: %d\nrules: ['MATCH,DIRECT']\n", first, second))
	if err := attachIngressFixture(t, &e); err == nil || !strings.Contains(err.Error(), "socks-port UDP") {
		t.Fatalf("partial-start bind error not surfaced: %v", err)
	}
	if e.tun != nil || e.cfg != nil {
		t.Fatal("failed ingress retained a live native lease")
	}
	assertIngressBindable(t, first)
	_ = occupied.Close()
	assertIngressBindable(t, second)
}

func TestOrdinaryNTPStartsOnlyAfterAttachAndUsesPublicApplicationClock(t *testing.T) {
	server, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	port := server.LocalAddr().(*net.UDPAddr).Port
	body := fmt.Sprintf("ipv6: false\nntp: {enable: true, server: 127.0.0.1, port: %d, interval: 1, write-to-system: false}\nrules: ['MATCH,DIRECT']\n", port)
	var e Engine
	home := t.TempDir()
	if err := e.Prepare(home, []byte(body), "", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, 512)
	_ = server.SetReadDeadline(time.Now().Add(30 * time.Millisecond))
	if _, _, err := server.ReadFrom(buffer); err == nil {
		t.Fatal("PREVIEW started unrelated NTP network work")
	}
	requireStop(t, &e)
	if err := e.PrepareWithOptions(home, []byte(body), "", nil, func(int) bool { return true }, PrepareOptions{Purpose: "VPN", Generation: 7, Composition: "ntp"}); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	if err := attachIngressFixture(t, &e); err != nil {
		t.Fatal(err)
	}
	_ = server.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, remote, err := server.ReadFrom(buffer)
	if err != nil || n != 48 || buffer[0]&7 != 3 {
		t.Fatalf("public NTP service did not send its real request: %d %v", n, err)
	}
	// Controlled NTP peer used by the test.
	response := make([]byte, 48)
	response[0], response[1] = 0x24, 1 // v4 server, primary stratum
	copy(response[24:32], buffer[40:48])
	now := time.Now().Add(time.Second)
	stamp := uint64(now.Unix()+2208988800)<<32 | uint64(now.Nanosecond())*(uint64(1)<<32)/1000000000
	binary.BigEndian.PutUint64(response[32:40], stamp)
	binary.BigEndian.PutUint64(response[40:48], stamp)
	if _, err := server.WriteTo(response, remote); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Until(deadline) > 0 && clock.Now().Sub(time.Now()) < 500*time.Millisecond {
		time.Sleep(time.Millisecond)
	}
	if delta := clock.Now().Sub(time.Now()); delta < 500*time.Millisecond || delta > 2*time.Second {
		t.Fatal("public application clock did not consume controlled NTP reply", delta)
	}
	requireStop(t, &e)
	deadline = time.Now().Add(2 * time.Second)
	for time.Until(deadline) > 0 && clock.Now().Sub(time.Now()) > 500*time.Millisecond {
		time.Sleep(time.Millisecond)
	}
	if clock.Now().Sub(time.Now()) > 500*time.Millisecond {
		t.Fatal("observed NTP loop did not cancel/reset its offset")
	}
	// Observe cancellation of this specific NTP exchange.
}

func TestOrdinaryNTPInvalidZeroIsNotSilentlyDefaultedAndRollsBackTun(t *testing.T) {
	var e Engine
	prepareVPN(t, &e, "ipv6: false\nntp: {enable: true, server: 127.0.0.1, port: 0, interval: 1}\nrules: ['MATCH,DIRECT']\n")
	if err := attachIngressFixture(t, &e); err == nil || !strings.Contains(err.Error(), "ntp: invalid") {
		t.Fatal("explicit NTP zero was hidden", err)
	}
	if e.tun != nil || e.cfg != nil {
		t.Fatal("failed NTP startup retained native lease")
	}
}

func TestNamedTLSConstructionFailureClosesSocketAllocatedBeforeError(t *testing.T) {
	port := ingressPort(t)
	var e Engine
	prepareVPN(t, &e, fmt.Sprintf("ipv6: false\nlisteners:\n  - {name: invalid-cert, type: http, listen: 127.0.0.1, port: %d, certificate: missing.crt, private-key: missing.key}\nrules: ['MATCH,DIRECT']\n", port))
	if err := attachIngressFixture(t, &e); err == nil || !strings.Contains(err.Error(), "invalid-cert") {
		t.Fatalf("post-bind TLS constructor error not surfaced: %v", err)
	}
	if e.failed {
		t.Fatal("safe HTTP rollback was incorrectly marked unconfirmed")
	}
	assertIngressBindable(t, port)
}
