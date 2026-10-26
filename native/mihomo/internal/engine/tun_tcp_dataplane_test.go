//go:build linux && !android && with_gvisor

package engine

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/metacubex/gvisor/pkg/buffer"
	"github.com/metacubex/gvisor/pkg/tcpip"
	"github.com/metacubex/gvisor/pkg/tcpip/adapters/gonet"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/link/channel"
	"github.com/metacubex/gvisor/pkg/tcpip/network/ipv4"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
	"github.com/metacubex/gvisor/pkg/tcpip/transport/tcp"
	"github.com/metacubex/mihomo/component/resolver"
)

// Use a public netstack TCP peer with real external-FD packets. System/mixed kernel
// routing requires separate device validation.
func TestUserspaceStacksExternalFDRealTCP(t *testing.T) {
	for _, name := range []string{"mips", "gvisor"} {
		t.Run(name, func(t *testing.T) {
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
