//go:build linux && !android

package engine

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	A "github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/listener/shadowsocks"
	"github.com/metacubex/mihomo/listener/sing_vmess"
	clock "github.com/metacubex/mihomo/ntp"
	D "github.com/miekg/dns"
)

func ingressPort(t *testing.T, excluded ...int) int {
	t.Helper()
	for i := 0; i < 20; i++ {
		tcp, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		port := tcp.Addr().(*net.TCPAddr).Port
		if slices.Contains(excluded, port) {
			_ = tcp.Close()
			continue
		}
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
	resource := &testTunResource{fd: fd, replacement: -1}
	t.Cleanup(func() {
		if resource.replacement >= 0 {
			_ = syscall.Close(resource.replacement)
		}
	})
	return e.attach(fd, 1, testTunConstructor(resource))
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
	if isolateEngineTest(t) {
		return
	}

	for _, purpose := range []string{"PREVIEW", "RUNNING"} {
		t.Run(fmt.Sprint(purpose), func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			home := t.TempDir()
			roots, certificate, privateKey := ingressCertificate(t, home)
			ports := make([]int, 6)
			for i := range ports {
				ports[i] = ingressPort(t, ports[:i]...)
			}
			httpPort, socksPort, mixedPort, tlsPort, tunnelPort, dnsPort := ports[0], ports[1], ports[2], ports[3], ports[4], ports[5]
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
			var e Engine
			if purpose == "PREVIEW" {
				if err := e.Prepare(home, []byte(body), "", func(int) bool { return true }); err != nil {
					t.Fatal(err)
				}
				defer requireStop(t, &e)
				for _, port := range ports {
					assertIngressBindable(t, port)
				}
				return
			}
			if err := e.PrepareWithOptions(home, []byte(body), "", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 7, Composition: "ingress"}); err != nil {
				t.Fatal(err)
			}
			defer requireStop(t, &e)
			// RUNNING的公开listeners在Prepare中启动；Attach不重复Listen。
			for _, port := range ports {
				conn, err := net.DialTimeout("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), time.Second)
				if err != nil {
					t.Fatalf("Prepare未启动listener %d: %v", port, err)
				}
				_ = conn.Close()
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

		})
	}
}

func TestIngressBindFailureRollsBackEarlierListenersAndTUN(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	first := ingressPort(t)
	second := ingressPort(t, first)
	occupied, err := net.ListenPacket("udp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(second)))
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	var e Engine
	body := fmt.Sprintf("ipv6: false\nport: %d\nsocks-port: %d\nrules: ['MATCH,DIRECT']\n", first, second)
	err = e.PrepareWithOptions(t.TempDir(), []byte(body), "rule", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 7, Composition: "ingress"})
	defer requireStop(t, &e)
	var socket *net.OpError
	if !errors.As(err, &socket) || !errors.Is(err, syscall.EADDRINUSE) {
		t.Fatalf("Prepare丢失实际bind错误: %v", err)
	}
	if e.tun != nil || e.cfg != nil {
		t.Fatal("failed ingress retained a live native lease")
	}
	assertIngressBindable(t, first)
	_ = occupied.Close()
	assertIngressBindable(t, second)
}

func TestOrdinaryNTPStartsDuringRunningPrepareAndUsesPublicApplicationClock(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}

	for _, purpose := range []string{"PREVIEW", "RUNNING"} {
		t.Run(fmt.Sprint(purpose), func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			server, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			port := server.LocalAddr().(*net.UDPAddr).Port
			body := fmt.Sprintf("ipv6: false\nntp: {enable: true, server: 127.0.0.1, port: %d, interval: 1, write-to-system: false}\nrules: ['MATCH,DIRECT']\n", port)
			var e Engine
			home := t.TempDir()
			buffer := make([]byte, 512)
			if purpose == "PREVIEW" {
				if err := e.Prepare(home, []byte(body), "", func(int) bool { return true }); err != nil {
					t.Fatal(err)
				}
				defer requireStop(t, &e)
				_ = server.SetReadDeadline(time.Now().Add(30 * time.Millisecond))
				if _, _, err := server.ReadFrom(buffer); err == nil {
					t.Fatal("PREVIEW started unrelated NTP network work")
				}
				return
			}
			if err := e.PrepareWithOptions(home, []byte(body), "", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 7, Composition: "ntp"}); err != nil {
				t.Fatal(err)
			}
			defer requireStop(t, &e)
			_ = server.SetReadDeadline(time.Now().Add(2 * time.Second))
			n, remote, err := server.ReadFrom(buffer)
			if err != nil || n != 48 || buffer[0]&7 != 3 {
				t.Fatalf("public NTP service did not send its real request: %d %v", n, err)
			}
			if err := attachIngressFixture(t, &e); err != nil {
				t.Fatal(err)
			}
			// 测试peer返回公开NTP wire response。
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

		})
	}
}

func TestOrdinaryNTPExplicitZeroUsesPublicCoreWithoutDefaulting(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	prepareVPN(t, &e, "ipv6: false\nntp: {enable: true, server: 127.0.0.1, port: 0, interval: 1}\nrules: ['MATCH,DIRECT']\n")
	defer requireStop(t, &e)
	if err := attachIngressFixture(t, &e); err != nil {
		t.Fatal("application prevalidated the public NTP service", err)
	}
	if e.tun == nil || e.cfg == nil || !e.cfg.NTP.Enable || e.cfg.NTP.Port != 0 || e.cfg.NTP.Interval != 1 {
		t.Fatal("explicit NTP zero was defaulted or prevented the real VPN attachment")
	}
}

func TestNamedTLSConstructionFailureClosesSocketAllocatedBeforeError(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	port := ingressPort(t)
	var e Engine
	body := fmt.Sprintf("ipv6: false\nlisteners:\n  - {name: invalid-cert, type: http, listen: 127.0.0.1, port: %d, certificate: missing.crt, private-key: missing.key}\nrules: ['MATCH,DIRECT']\n", port)
	err := e.PrepareWithOptions(t.TempDir(), []byte(body), "rule", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 7, Composition: "tls"})
	defer requireStop(t, &e)
	if err == nil || !strings.Contains(err.Error(), "parse certificate failed") || !strings.Contains(err.Error(), "missing.crt") {
		t.Fatalf("Prepare未返回公开TLS构造错误: %v", err)
	}
	if e.failed {
		t.Fatal("safe HTTP rollback was incorrectly marked unconfirmed")
	}
	assertIngressBindable(t, port)
}

func TestResourceCopyOnlyDefersResourcesWithoutChangingProfileOrTrust(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, selected := range []bool{false, true} {
		t.Run(strconv.FormatBool(selected), func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			raw, err := config.UnmarshalRawConfig([]byte(fmt.Sprintf(`port: 12345
socks-port: 12346
mixed-port: 12347
tun: {enable: true, mtu: 1420}
dns: {enable: false, enhanced-mode: redir-host, listen: '127.0.0.1:5353', listen-routing-mark: 12}
ntp: {enable: true, server: 127.0.0.1, port: 0, interval: 0, write-to-system: false}
profile: {store-selected: %t, store-fake-ip: false}
tls: {custom-certifactes: [original-certificate]}
external-ui: original-ui
external-ui-url: https://fixture.invalid/original.zip
external-ui-name: original-name
rules: ['MATCH,DIRECT']
`, selected)))
			if err != nil {
				t.Fatal(err)
			}
			cfg, err := config.ParseRawConfig(raw)
			if err != nil {
				t.Fatal(err)
			}
			baseline := Engine{cfg: cfg}
			defer requireStop(t, &baseline)
			general, dns, ntp, controller := *cfg.General, *cfg.DNS, *cfg.NTP, *cfg.Controller
			embed, system := ca.DisableEmbedCa, ca.DisableSystemCa
			defer func() { ca.DisableEmbedCa, ca.DisableSystemCa = embed, system }()
			ca.DisableEmbedCa, ca.DisableSystemCa = selected, !selected
			copy := workingConfig(cfg, true)
			if copy == cfg || copy.General == cfg.General || copy.DNS == cfg.DNS || copy.NTP == cfg.NTP {
				t.Fatal("deferred resource settings were not copied")
			}
			if copy.General.Port != 0 || copy.General.SocksPort != 0 || copy.General.MixedPort != 0 || copy.General.Tun.Enable || copy.DNS.Listen != "" || copy.NTP.Enable {
				t.Fatal("resource preparation would open external ingress or NTP")
			}
			if copy.General.Tun.MTU != 1420 || copy.DNS.ListenRoutingMark != 12 || copy.NTP.Port != 0 || copy.NTP.Interval != 0 || copy.Controller.ExternalUI != "" {
				t.Fatal("resource copy changed options beyond deferred work")
			}
			if copy.Profile != cfg.Profile || copy.TLS != cfg.TLS || copy.Profile.StoreSelected != selected || !reflect.DeepEqual(copy.TLS.CustomTrustCert, []string{"original-certificate"}) {
				t.Fatal("profile or custom TLS certificates were rewritten")
			}
			if ca.DisableEmbedCa != selected || ca.DisableSystemCa != !selected {
				t.Fatal("resource preparation changed the process trust policy")
			}
			if !reflect.DeepEqual(general, *cfg.General) || !reflect.DeepEqual(dns, *cfg.DNS) || !reflect.DeepEqual(ntp, *cfg.NTP) || !reflect.DeepEqual(controller, *cfg.Controller) {
				t.Fatal("resource preparation changed the effective configuration")
			}
		})
	}
}

func TestIngressParseFailuresKeepThePublicCauseAndReleaseTheAttachedTun(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, field := range []string{"ss-config", "vmess-config", "dns.listen"} {
		t.Run(field, func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			value := "127.0.0.1"
			var original error
			var body string
			switch field {
			case "ss-config":
				value = "ss://cipher:fixture%zz@127.0.0.1:1"
				_, _, _, original = shadowsocks.ParseSSURL(value)
				body = fmt.Sprintf("ss-config: %q\n", value)
			case "vmess-config":
				value = "vmess://user:fixture%zz@127.0.0.1:1"
				_, _, _, original = sing_vmess.ParseVmessURL(value)
				body = fmt.Sprintf("vmess-config: %q\n", value)
			case "dns.listen":
				_, _, original = net.SplitHostPort(value)
				body = fmt.Sprintf("dns: {enable: true, listen: %q}\n", value)
			}
			if original == nil {
				t.Fatal("fixture must fail at the public parser")
			}
			var e Engine
			body = "ipv6: false\n" + body + "rules: ['MATCH,DIRECT']\n"
			err := e.PrepareWithOptions(t.TempDir(), []byte(body), "rule", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 7, Composition: "parse"})
			if err == nil || !strings.Contains(err.Error(), original.Error()) {
				t.Fatalf("public parser cause was replaced: %v; want %v", err, original)
			}
			if field == "dns.listen" {
				var cause *net.AddrError
				if !errors.As(err, &cause) || cause.Addr != value {
					t.Fatalf("actual address error was lost: %v", err)
				}
			} else {
				var cause *url.Error
				if !errors.As(err, &cause) || cause.URL != value {
					t.Fatalf("actual URL error was lost: %v", err)
				}
			}
			if e.tun != nil || e.cfg != nil || e.owner != nil || e.failed {
				t.Fatal("a parse error retained resources or fabricated a cleanup failure")
			}
			requireStop(t, &e)
		})
	}
}

func TestNTPNonpositiveIntervalsRemainPublicNoOpsWithoutDefaulting(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, interval := range []int{0, -1} {
		t.Run(strconv.Itoa(interval), func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			server, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			port := server.LocalAddr().(*net.UDPAddr).Port
			var e Engine
			prepareVPN(t, &e, fmt.Sprintf("ipv6: false\nntp: {enable: true, server: 127.0.0.1, port: %d, interval: %d}\nrules: ['MATCH,DIRECT']\n", port, interval))
			defer requireStop(t, &e)
			if err := attachIngressFixture(t, &e); err != nil {
				t.Fatalf("application rejected the public NTP no-op: %v", err)
			}
			if e.tun == nil || !e.cfg.NTP.Enable || e.cfg.NTP.Interval != interval || e.cfg.NTP.Port != port {
				t.Fatal("NTP inputs were defaulted or attachment was erased")
			}
			if err := server.SetReadDeadline(time.Now().Add(30 * time.Millisecond)); err != nil {
				t.Fatal(err)
			}
			if _, _, err := server.ReadFrom(make([]byte, 512)); err == nil {
				t.Fatal("a public no-op interval started an NTP request")
			} else if failure, ok := err.(net.Error); !ok || !failure.Timeout() {
				t.Fatal(err)
			}
		})
	}
}

func TestDNSListenerAppliesRoutingMarkOrReturnsTheActualSocketError(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	const mark = 12
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(ingressPort(t)))
	lc := A.NewListenConfig()
	lc.SetRouteMark(mark)
	listener, original := lc.Listen(context.Background(), "tcp", address)
	if original == nil {
		if err := listener.Close(); err != nil {
			t.Fatal(err)
		}
	}
	var e Engine
	body := fmt.Sprintf("ipv6: false\ndns: {enable: true, listen: %q, listen-routing-mark: %d}\nrules: ['MATCH,DIRECT']\n", address, mark)
	err := e.PrepareWithOptions(t.TempDir(), []byte(body), "rule", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 7, Composition: "dns-mark"})
	defer requireStop(t, &e)
	if original != nil {
		var socket *net.OpError
		if err == nil || !strings.Contains(err.Error(), original.Error()) || !errors.As(err, &socket) {
			t.Fatalf("actual routing-mark socket error was replaced or ignored: %v; want %v", err, original)
		}
		if e.tun != nil || e.cfg != nil || e.owner != nil || e.failed {
			t.Fatal("failed socket setup retained the VPN lease or fabricated a cleanup failure")
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	states := e.listenerStates.Snapshot()
	if len(states) != 2 || states[0].State != "bound" || states[1].State != "bound" {
		t.Fatal("缺少实际DNS TCP/UDP socket", states)
	}
}
