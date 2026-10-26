//go:build linux && !android && with_gvisor

package engine

import (
	"fmt"
	"net"
	"os"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/metacubex/gopacket"
	"github.com/metacubex/gopacket/layers"
	"github.com/metacubex/mihomo/component/resolver"
	D "github.com/miekg/dns"
	"net/netip"
)

func ipv4UDPPacket(t *testing.T, source, destination net.IP, sourcePort, destinationPort int, payload []byte) []byte {
	t.Helper()
	ip := &layers.IPv4{Version: 4, IHL: 5, TTL: 64, SrcIP: source, DstIP: destination, Protocol: layers.IPProtocolUDP}
	udp := &layers.UDP{SrcPort: layers.UDPPort(sourcePort), DstPort: layers.UDPPort(destinationPort)}
	if err := udp.SetNetworkLayerForChecksum(ip); err != nil {
		t.Fatal(err)
	}
	buffer := gopacket.NewSerializeBuffer()
	if err := gopacket.SerializeLayers(buffer, gopacket.SerializeOptions{FixLengths: true, ComputeChecksums: true}, ip, udp, gopacket.Payload(payload)); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func readTunUDP(t *testing.T, peer *os.File, destinationPort int) []byte {
	t.Helper()
	if err := peer.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, 65535)
	for {
		n, err := peer.Read(buffer)
		if err != nil {
			t.Fatal(err)
		}
		var ip layers.IPv4
		if err := ip.DecodeFromBytes(buffer[:n], gopacket.NilDecodeFeedback); err != nil {
			t.Fatal(err)
		}
		if ip.Protocol != layers.IPProtocolUDP {
			continue
		}
		var udp layers.UDP
		if err := udp.DecodeFromBytes(ip.Payload, gopacket.NilDecodeFeedback); err != nil {
			t.Fatal(err)
		}
		if int(udp.DstPort) == destinationPort {
			return append([]byte(nil), udp.Payload...)
		}
	}
}

// Unix datagram pairs exercise actual external-FD UDP, DNS hijack and rule-rejection
// paths for each selected stack. System/mixed TCP has separate device validation.
func TestFourStacksExternalFDRealUDPAndDNSAndRejection(t *testing.T) {
	for _, name := range []string{"mips", "gvisor", "mixed", "system"} {
		t.Run(name, func(t *testing.T) {
			dnsSocket, err := net.ListenPacket("udp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			dnsStarted := make(chan struct{})
			dnsServer := &D.Server{PacketConn: dnsSocket, NotifyStartedFunc: func() { close(dnsStarted) }, Handler: D.HandlerFunc(func(w D.ResponseWriter, request *D.Msg) {
				response := new(D.Msg).SetReply(request)
				response.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: request.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 30}, A: net.ParseIP("192.0.2.123")}}
				_ = w.WriteMsg(response)
			})}
			dnsDone := make(chan error, 1)
			go func() { dnsDone <- dnsServer.ActivateAndServe() }()
			select {
			case <-dnsStarted:
			case err := <-dnsDone:
				t.Fatal(err)
			case <-time.After(time.Second):
				t.Fatal("local DNS did not start")
			}
			defer func() { _ = dnsServer.Shutdown(); _ = dnsSocket.Close(); <-dnsDone }()
			allowed, err := net.ListenPacket("udp", "127.0.0.5:0")
			if err != nil {
				t.Fatal(err)
			}
			allowedDone := make(chan struct{})
			go func() {
				defer close(allowedDone)
				buffer := make([]byte, 4096)
				for {
					n, addr, err := allowed.ReadFrom(buffer)
					if err != nil {
						return
					}
					_, _ = allowed.WriteTo(buffer[:n], addr)
				}
			}()
			defer func() { _ = allowed.Close(); <-allowedDone }()
			denied, err := net.ListenPacket("udp", "127.0.0.5:0")
			if err != nil {
				t.Fatal(err)
			}
			var deniedPackets atomic.Int64
			deniedDone := make(chan struct{})
			go func() {
				defer close(deniedDone)
				buffer := make([]byte, 4096)
				for {
					_, _, err := denied.ReadFrom(buffer)
					if err != nil {
						return
					}
					deniedPackets.Add(1)
				}
			}()
			defer func() { _ = denied.Close(); <-deniedDone }()
			deniedPort := denied.LocalAddr().(*net.UDPAddr).Port
			// Use the loopback interface prefix for system/mixed kernel forwarding; inject
			// non-loopback IP packets through the external-FD path and actual DNS/hosts
			// configuration.
			body := fmt.Sprintf(`ipv6: false
find-process-mode: off
hosts: {controlled.echo.test: 127.0.0.5}
tun: {stack: %s, inet6-address: []}
dns:
  fake-ip-range: 127.0.0.1/16
  nameserver: ['%s']
  default-nameserver: [127.0.0.1]
rules:
  - DST-PORT,%d,REJECT
  - MATCH,DIRECT
`, name, dnsSocket.LocalAddr().String(), deniedPort)
			var e Engine
			prepareWithVPNOptions(t, &e, t.TempDir(), body, PrepareOptions{})
			pair, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM|syscall.SOCK_NONBLOCK, 0)
			if err != nil {
				t.Fatal(err)
			}
			peer := os.NewFile(uintptr(pair[1]), "external-TUN-packet-peer")
			defer peer.Close()
			if err := e.Attach(pair[0], e.spec.Revision); err != nil {
				t.Fatalf("actual %s external-FD startup: %v", name, err)
			}
			question := new(D.Msg)
			question.SetQuestion(name+".dataplane.test.", D.TypeA)
			query, err := question.Pack()
			if err != nil {
				t.Fatal(err)
			}
			if _, err := peer.Write(ipv4UDPPacket(t, net.ParseIP("198.18.0.1"), net.ParseIP("198.18.0.2"), 41001, 53, query)); err != nil {
				t.Fatal(err)
			}
			var response D.Msg
			if err := response.Unpack(readTunUDP(t, peer, 41001)); err != nil {
				t.Fatal(err)
			}
			if response.Rcode != D.RcodeSuccess || len(response.Answer) != 1 || response.Answer[0].(*D.A).A.String() != "192.0.2.123" {
				t.Fatalf("%s TUN DNS response is not real upstream data: %s", name, &response)
			}
			resolver.InsertHostByIP(netip.MustParseAddr("192.0.2.5"), "controlled.echo.test")
			payload := []byte("real-" + name + "-UDP-echo")
			if _, err := peer.Write(ipv4UDPPacket(t, net.ParseIP("198.18.0.1"), net.ParseIP("192.0.2.5"), 41002, allowed.LocalAddr().(*net.UDPAddr).Port, payload)); err != nil {
				t.Fatal(err)
			}
			if response := string(readTunUDP(t, peer, 41002)); response != string(payload) {
				t.Fatalf("%s UDP data changed: %q", name, response)
			}
			if _, err := peer.Write(ipv4UDPPacket(t, net.ParseIP("198.18.0.1"), net.ParseIP("192.0.2.5"), 41003, deniedPort, []byte("must-not-arrive"))); err != nil {
				t.Fatal(err)
			}
			// Wait for this exact rule-decision signal.
			matched := false
			deadline := time.Now().Add(time.Second)
			for !matched && time.Now().Before(deadline) {
				for _, entry := range e.logs.page(LogQuery{Limit: 500}).Entries {
					if strings.Contains(entry.Text, fmt.Sprintf("DstPort(%d)", deniedPort)) && strings.Contains(entry.Text, "using REJECT") {
						matched = true
						break
					}
				}
				if !matched {
					time.Sleep(time.Millisecond)
				}
			}
			if !matched {
				t.Fatal("the rejected packet never reached its actual rule decision")
			}
			requireStop(t, &e)
			if deniedPackets.Load() != 0 {
				t.Fatalf("%s forwarded a rule-rejected UDP packet", name)
			}
			var stat syscall.Stat_t
			if err := syscall.Fstat(pair[0], &stat); err == nil {
				t.Fatal("external descriptor remained open after normal Stop")
			}
		})
	}
}
