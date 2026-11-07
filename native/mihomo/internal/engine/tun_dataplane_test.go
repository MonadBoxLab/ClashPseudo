//go:build linux && !android && with_gvisor

package engine

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"clashpseudo/native/internal/ingress"
	"github.com/metacubex/gopacket"
	"github.com/metacubex/gopacket/layers"
	"github.com/metacubex/gvisor/pkg/buffer"
	"github.com/metacubex/gvisor/pkg/tcpip"
	"github.com/metacubex/gvisor/pkg/tcpip/adapters/gonet"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/link/channel"
	"github.com/metacubex/gvisor/pkg/tcpip/network/ipv4"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
	"github.com/metacubex/gvisor/pkg/tcpip/transport/tcp"
	"github.com/metacubex/mihomo/component/resolver"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/tunnel"
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
	if isolateEngineTest(t) {
		return
	}
	for _, name := range []string{"mips", "gvisor", "mixed", "system"} {
		t.Run(name, func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
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
tun: {stack: %s, inet4-address: [127.0.0.1/16], inet6-address: []}
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
			if err := e.attach(pair[0], e.spec.Revision, func(fd int, options LC.Tun, dnsAddresses []netip.AddrPort) (tunResource, error, bool) {
				// Unix sockets have no TUN interface name; Linux system/mixed fixtures use the real lo interface for kernel forwarding.
				if name == "system" || name == "mixed" {
					options.Device = "lo"
				}
				return ingress.NewTun(fd, options, dnsAddresses, tunnel.Tunnel)
			}); err != nil {
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
			// Wait for the log record of this actual rule decision.
			matched := false
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			for !matched {
				entry, err := e.LogQueue().Next(ctx)
				if err != nil {
					break
				}
				matched = strings.Contains(entry.Text, fmt.Sprintf("DstPort(%d)", deniedPort)) && strings.Contains(entry.Text, "using REJECT")
			}
			cancel()
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

// Use a public netstack TCP peer with real external-FD packets. System/mixed kernel
// routing requires separate device validation.
func TestUserspaceStacksExternalFDRealTCP(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, name := range []string{"mips", "gvisor"} {
		t.Run(name, func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			listener, err := net.Listen("tcp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			var tasks sync.WaitGroup
			var errorMu sync.Mutex
			var serverErrors []error
			serverDone := make(chan struct{})
			go func() {
				defer close(serverDone)
				for {
					conn, err := listener.Accept()
					if err != nil {
						return
					}
					tasks.Add(1)
					go func() {
						defer tasks.Done()
						defer conn.Close()
						_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
						data := make([]byte, 16)
						_, err := io.ReadFull(conn, data)
						if err == nil {
							_, err = conn.Write(data)
						}
						if err != nil {
							errorMu.Lock()
							serverErrors = append(serverErrors, err)
							errorMu.Unlock()
						}
					}()
				}
			}()
			t.Cleanup(func() {
				_ = listener.Close()
				<-serverDone
				tasks.Wait()
				for _, err := range serverErrors {
					t.Errorf("loopback TCP task: %v", err)
				}
			})
			var e Engine
			prepareWithVPNOptions(t, &e, t.TempDir(), fmt.Sprintf(`ipv6: false
find-process-mode: off
hosts: {controlled.tcp.test: 127.0.0.1}
tun: {stack: %s, inet6-address: []}
dns: {enable: true, enhanced-mode: redir-host, nameserver: [127.0.0.1], default-nameserver: [127.0.0.1], fallback: []}
rules: ['MATCH,DIRECT']
`, name), PrepareOptions{})
			resolver.InsertHostByIP(netip.MustParseAddr("192.0.2.5"), "controlled.tcp.test")
			pair, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM|syscall.SOCK_NONBLOCK, 0)
			if err != nil {
				t.Fatal(err)
			}
			peer := os.NewFile(uintptr(pair[1]), "external-TUN-TCP-peer")
			if err := e.Attach(pair[0], e.spec.Revision); err != nil {
				_ = peer.Close()
				t.Fatal(err)
			}
			client := stack.New(stack.Options{
				NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol},
				TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol},
			})
			endpoint := channel.New(1024, 1500, "")
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			var packets sync.WaitGroup
			t.Cleanup(func() {
				cancel()
				client.Close()
				endpoint.Close()
				_ = peer.Close()
				packets.Wait()
				client.Wait()
			})
			if err := client.CreateNIC(1, endpoint); err != nil {
				t.Fatal(err)
			}
			if err := client.AddProtocolAddress(1, tcpip.ProtocolAddress{Protocol: ipv4.ProtocolNumber,
				AddressWithPrefix: tcpip.AddrFrom4([4]byte{198, 18, 0, 1}).WithPrefix()}, stack.AddressProperties{}); err != nil {
				t.Fatal(err)
			}
			client.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}})
			_ = peer.SetDeadline(time.Now().Add(15 * time.Second))
			packets.Add(2)
			go func() {
				defer packets.Done()
				for {
					packet := endpoint.ReadContext(ctx)
					if packet == nil {
						return
					}
					view := packet.ToView()
					_, err := peer.Write(view.AsSlice())
					view.Release()
					packet.DecRef()
					if err != nil {
						return
					}
				}
			}()
			go func() {
				defer packets.Done()
				data := make([]byte, 65535)
				for {
					n, err := peer.Read(data)
					if err != nil {
						return
					}
					packet := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(append([]byte(nil), data[:n]...))})
					endpoint.InjectInbound(ipv4.ProtocolNumber, packet)
					packet.DecRef()
				}
			}()
			ports := make(map[int]bool)
			for i := 0; i < 32; i++ {
				conn, err := gonet.DialContextTCP(ctx, client, tcpip.FullAddress{NIC: 1,
					Addr: tcpip.AddrFrom4([4]byte{192, 0, 2, 5}), Port: uint16(listener.Addr().(*net.TCPAddr).Port)}, ipv4.ProtocolNumber)
				if err != nil {
					t.Fatalf("actual %s TCP handshake %d: %v", name, i, err)
				}
				_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
				payload := []byte(fmt.Sprintf("owned-tcp-%06d", i))
				_, writeErr := conn.Write(payload)
				response := make([]byte, len(payload))
				_, readErr := io.ReadFull(conn, response)
				var after [1]byte
				n, eofErr := conn.Read(after[:])
				port := conn.LocalAddr().(*net.TCPAddr).Port
				closeErr := conn.Close()
				if writeErr != nil || readErr != nil || closeErr != nil || !bytes.Equal(payload, response) || ports[port] || n != 0 || eofErr != io.EOF {
					t.Fatalf("%s flow %d: write=%v read=%v close=%v exactEcho=%v uniquePort=%v after=%d/%v",
						name, i, writeErr, readErr, closeErr, bytes.Equal(payload, response), !ports[port], n, eofErr)
				}
				ports[port] = true
			}
			t.Logf("%s: 32 unique TCP handshakes and exact two-way payloads through actual external FD", name)
		})
	}
}
