//go:build linux && !android

package ingress

import (
	"context"
	"errors"
	"flag"
	"io"
	"net"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	A "github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/listener"
	IN "github.com/metacubex/mihomo/listener/inbound"
	"github.com/metacubex/mihomo/tunnel"
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

func TestListenConfigCloseClosesOwnedAndLateSockets(t *testing.T) {
	guard := newListenConfig("test", &net.ListenConfig{}, Options{})
	defer guard.Close()
	tcp, err := guard.Listen(context.Background(), "tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer tcp.Close()
	udp, err := guard.ListenPacket(context.Background(), "udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	if len(guard.resources) == 0 {
		t.Fatal("successful raw allocations were not retained for rollback")
	}
	_ = tcp.(*observedListener).Listener.(*net.TCPListener).SetDeadline(time.Now().Add(time.Second))
	_ = udp.SetReadDeadline(time.Now().Add(time.Second))
	if err := guard.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := tcp.Accept(); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("rollback retained TCP listener: %v", err)
	}
	if _, _, err := udp.ReadFrom(make([]byte, 1)); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("rollback retained UDP socket: %v", err)
	}
	if len(guard.resources) > 0 {
		t.Fatal("rollback retained resource ownership")
	}
	// Late allocations must be closed before returning net.ErrClosed, not leaked.
	if late, err := guard.Listen(context.Background(), "tcp4", tcp.Addr().String()); !errors.Is(err, net.ErrClosed) || late != nil {
		if late != nil {
			_ = late.Close()
		}
		t.Fatalf("late TCP allocation was admitted: %v", err)
	}
	if late, err := guard.ListenPacket(context.Background(), "udp4", udp.LocalAddr().String()); !errors.Is(err, net.ErrClosed) || late != nil {
		if late != nil {
			_ = late.Close()
		}
		t.Fatalf("late UDP allocation was admitted: %v", err)
	}
	for _, port := range []int{tcp.Addr().(*net.TCPAddr).Port, udp.LocalAddr().(*net.UDPAddr).Port} {
		assertIngressBindable(t, port)
	}
	if err := guard.Close(); err != nil {
		t.Fatalf("repeated rollback was not idempotent: %v", err)
	}
}

func TestListenerRegistryKeepsOwnershipUntilExplicitClose(t *testing.T) {
	observer := &Observer{}
	guard := newListenConfig("test", &net.ListenConfig{}, Options{Observer: observer})
	tcp, err := guard.Listen(context.Background(), "tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = observer.register("exact-name", guard); err != nil {
		t.Fatal(err)
	}
	udp, err := guard.ListenPacket(context.Background(), "udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.DialTimeout("tcp4", tcp.Addr().String(), time.Second)
	if err != nil {
		t.Fatal("登记资源时提前关闭了socket", err)
	}
	_ = conn.Close()
	if err = observer.CloseListener("exact"); err == nil {
		t.Fatal("按前缀认领了其他监听")
	}
	if _, err = udp.WriteTo([]byte("owned"), udp.LocalAddr()); err != nil {
		t.Fatal(err)
	}
	if err = udp.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, 16)
	if n, _, err := udp.ReadFrom(buffer); err != nil || string(buffer[:n]) != "owned" {
		t.Fatal("登记资源关闭了已交接的UDP socket", err)
	}
	if err = observer.CloseListener("exact-name"); err != nil {
		t.Fatal(err)
	}
	if err = observer.CloseListener("exact-name"); err != nil {
		t.Fatal("重复关闭不是幂等操作", err)
	}
	if _, err = tcp.Accept(); !errors.Is(err, net.ErrClosed) {
		t.Fatal("TCP未关闭", err)
	}
	if _, _, err = udp.ReadFrom(make([]byte, 1)); !errors.Is(err, net.ErrClosed) {
		t.Fatal("UDP未关闭", err)
	}
	states := observer.Snapshot()
	if len(states) != 2 {
		t.Fatal("状态记录保存了第二份事件历史", states)
	}
	for _, state := range states {
		if state.State != "closed" {
			t.Fatal("实际Close未反映到状态", state)
		}
	}
}

func TestListenConfigBindFailureDoesNotOwnOtherSockets(t *testing.T) {
	occupied, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	guard := newListenConfig("test", &net.ListenConfig{}, Options{})
	defer guard.Close()
	if conn, err := guard.ListenPacket(context.Background(), "udp4", occupied.LocalAddr().String()); err == nil || conn != nil {
		if conn != nil {
			_ = conn.Close()
		}
		t.Fatalf("occupied UDP bind did not fail: %v", err)
	}
	if len(guard.resources) > 0 {
		t.Fatal("failed allocation claimed another owner's socket")
	}
	if err := guard.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := occupied.WriteTo([]byte("still-owned"), occupied.LocalAddr()); err != nil {
		t.Fatalf("rollback closed another owner's socket: %v", err)
	}
	_ = occupied.SetReadDeadline(time.Now().Add(time.Second))
	buffer := make([]byte, 16)
	if n, _, err := occupied.ReadFrom(buffer); err != nil || string(buffer[:n]) != "still-owned" {
		t.Fatalf("unrelated socket no longer works: %q %v", buffer[:n], err)
	}
}

func TestDNSListenerRetainsBothSocketsAndTheirActualRoutingMark(t *testing.T) {
	previous := resolver.DefaultService
	resolver.DefaultService = dns.NewService(nil, dns.NewEnhancer(dns.EnhancerConfig{EnhancedMode: C.DNSNormal}))
	t.Cleanup(func() { dns.ReCreateServer("", nil, nil); resolver.DefaultService = previous })
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
	var marks []int
	var marksMu sync.Mutex
	observer := &Observer{}
	cfg := &config.Config{General: &config.General{}, DNS: &config.DNS{Enable: true, Listen: address, ListenRoutingMark: mark}}
	result := Activate(cfg, nil, Options{Observer: observer, Protect: func(fd int) error {
		actual, err := syscall.GetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_MARK)
		marksMu.Lock()
		marks = append(marks, actual)
		marksMu.Unlock()
		return err
	}})
	if original != nil {
		if result.Err == nil || !strings.Contains(result.Err.Error(), original.Error()) || result.CleanupUncertain || len(result.Resources) != 0 {
			t.Fatal("原始routing mark错误或失败清理状态被改变", result.Err, original, result.CleanupUncertain, len(result.Resources))
		}
		return
	}
	if result.Err != nil || result.CleanupUncertain {
		t.Fatal(result.Err)
	}
	defer Close(result.Resources)
	marksMu.Lock()
	defer marksMu.Unlock()
	if len(marks) != 2 || marks[0] != mark || marks[1] != mark || len(observer.Snapshot()) != 2 {
		t.Fatal("未保留TCP/UDP实际routing mark", marks, observer.Snapshot())
	}
}

type orderedListener struct {
	C.InboundListener
	name                string
	option              *IN.HTTPOption
	events              *[]string
	listenErr, closeErr error
}

func (l *orderedListener) Config() C.InboundConfig {
	if l.option == nil {
		l.option = &IN.HTTPOption{}
	}
	return l.option
}
func (l *orderedListener) Name() string       { return l.name }
func (l *orderedListener) RawAddress() string { return "127.0.0.1:0" }
func (l *orderedListener) Listen(C.Tunnel) error {
	*l.events = append(*l.events, "listen:"+l.name)
	return l.listenErr
}
func (l *orderedListener) Close() error {
	*l.events = append(*l.events, "close:"+l.name)
	return l.closeErr
}

func TestResourceCloseUsesReverseOrderAndKeepsOriginalErrors(t *testing.T) {
	var events []string
	firstErr, secondErr := errors.New("first original close error"), errors.New("second original close error")
	first := &orderedListener{name: "a", events: &events, closeErr: firstErr}
	second := &orderedListener{name: "b", events: &events, closeErr: secondErr}
	third := &orderedListener{name: "c", events: &events}
	err := Close([]io.Closer{first, second, third})
	if !errors.Is(err, firstErr) || !errors.Is(err, secondErr) || !slices.Equal(events, []string{"close:c", "close:b", "close:a"}) {
		t.Fatal("Close顺序或原始cause丢失", events, err)
	}
}
func TestListenerRegistryClosesInReverseAcquisitionOrderAndKeepsErrors(t *testing.T) {
	var events []string
	firstErr, lastErr := errors.New("first original close error"), errors.New("last original close error")
	observer := &Observer{}
	for _, entry := range []struct {
		name string
		err  error
	}{{"z", firstErr}, {"a", nil}, {"m", lastErr}} {
		if _, err := observer.register(entry.name, &orderedListener{name: entry.name, events: &events, closeErr: entry.err}); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 2; i++ {
		err := observer.CloseAll()
		if !errors.Is(err, firstErr) || !errors.Is(err, lastErr) || !slices.Equal(events, []string{"close:m", "close:a", "close:z"}) {
			t.Fatal("registry没有按实际取得顺序反向关闭或丢失原错误", events, err)
		}
	}
}

func TestPrepareNamedLetsHubCallListenOnceAndActivateDoesNotRepeatIt(t *testing.T) {
	for _, fails := range []bool{false, true} {
		t.Run(strconv.FormatBool(fails), func(t *testing.T) {
			if os.Getenv("PSEUDO_NAMED_LISTENER_TEST") != t.Name() {
				ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				defer cancel()
				command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestPrepareNamedLetsHubCallListenOnceAndActivateDoesNotRepeatIt$/^"+strconv.FormatBool(fails)+"$", "-test.count=1")
				if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
					command.Args = append(command.Args, "-test.gocoverdir="+directory.Value.String())
				}
				command.Env = append(os.Environ(), "PSEUDO_NAMED_LISTENER_TEST="+t.Name())
				if output, err := command.CombinedOutput(); err != nil {
					t.Fatalf("独立named listener测试失败: %v\n%s", err, output)
				}
				return
			}

			raw, err := config.UnmarshalRawConfig([]byte("rules: ['MATCH,DIRECT']\n"))
			if err != nil {
				t.Fatal(err)
			}
			cfg, err := config.ParseRawConfig(raw)
			if err != nil {
				t.Fatal(err)
			}
			defer func() {
				for _, proxy := range cfg.Proxies {
					_ = proxy.Close()
				}
			}()
			events := []string{}
			original := errors.New("named original startup error")
			closeErr := errors.New("named original close error")
			named := &orderedListener{name: "named", events: &events, closeErr: closeErr}
			if fails {
				named.listenErr = original
			}
			cfg.Listeners = map[string]C.InboundListener{"named": named}
			observer := &Observer{}
			if err = PrepareNamed(cfg, Options{Observer: observer}); err != nil {
				t.Fatal(err)
			}
			hub.ApplyConfig(cfg)
			if !slices.Equal(events, []string{"listen:named"}) {
				t.Fatal("hub没有恰好调用一次原Listen", events)
			}
			if result := Activate(cfg, nil); result.Err != nil || len(result.Resources) != 0 || len(events) != 1 {
				t.Fatal("延后入口再次执行了named Listen", events, result.Err)
			}
			if fails {
				if !errors.Is(observer.Errors(), original) {
					t.Fatal("Listen原始cause丢失", observer.Errors())
				}
				if err = observer.CloseAll(); err != nil || !slices.Equal(events, []string{"listen:named"}) {
					t.Fatal("失败Listen认领了未交接的协议资源", events, err)
				}
			} else {
				if err = observer.CloseListener("named"); !errors.Is(err, closeErr) {
					t.Fatal("Close原始cause丢失", err)
				}
				_ = observer.CloseListener("named")
				if !slices.Equal(events, []string{"listen:named", "close:named"}) {
					t.Fatal("登记资源实际Close不止一次", events)
				}
			}
			listener.PatchInboundListeners(nil, tunnel.Tunnel, true)
		})
	}
}

func TestNamedListenerStartupFailureRollsBackAcquiredResourcesAndKeepsAllCauses(t *testing.T) {
	var events []string
	startup := errors.New("第三个named listener的原始Listen错误")
	firstClose, secondClose := errors.New("第一个named listener的原始Close错误"), errors.New("第二个named listener的原始Close错误")
	cfg := &config.Config{Listeners: map[string]C.InboundListener{
		"z": &orderedListener{name: "z", events: &events, closeErr: firstClose},
		"a": &orderedListener{name: "a", events: &events, closeErr: secondClose},
		"m": &orderedListener{name: "m", events: &events, listenErr: startup},
	}}
	observer := &Observer{}
	if err := PrepareNamed(cfg, Options{Observer: observer}); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"z", "a", "m"} {
		err := cfg.Listeners[name].Listen(nil)
		if name != "m" && err != nil {
			t.Fatal(err)
		}
		if name == "m" && !errors.Is(err, startup) {
			t.Fatal("失败入口丢失Listen的原始cause", err)
		}
	}
	if len(observer.owned) != 2 || observer.owned["m"] != nil {
		t.Fatal("失败Listen交接了尚未取得的协议资源")
	}
	err := errors.Join(observer.Errors(), observer.CloseAll())
	for _, original := range []error{startup, firstClose, secondClose} {
		if !errors.Is(err, original) {
			t.Fatal("回滚丢失原始cause", original, err)
		}
	}
	expected := []string{"listen:z", "listen:a", "listen:m", "close:a", "close:z"}
	if !slices.Equal(events, expected) {
		t.Fatal("回滚没有按取得顺序反向关闭全部named资源", events)
	}
	for _, listener := range cfg.Listeners {
		_ = listener.Close()
	}
	if !slices.Equal(events, expected) {
		t.Fatal("回滚后的named资源仍被重复关闭", events)
	}
}

func TestNamedListenFailureKeepsActualSocketCleanupCauseWithoutClosingUnstartedProtocol(t *testing.T) {
	var events []string
	startup, cleanup := errors.New("原始Listen错误"), errors.New("已分配socket的原始Close错误")
	protocol := &orderedListener{name: "failed", events: &events, listenErr: startup}
	socket := &orderedListener{name: "socket", events: &events, closeErr: cleanup}
	guard := newListenConfig("failed", &net.ListenConfig{}, Options{})
	guard.resources = []io.Closer{socket}
	observer := &Observer{}
	wrapped := &observedInbound{InboundListener: protocol, config: guard, observer: observer}
	err := wrapped.Listen(nil)
	if !errors.Is(err, startup) || !errors.Is(err, cleanup) || !errors.Is(observer.Errors(), startup) || !errors.Is(observer.Errors(), cleanup) {
		t.Fatal("Listen或实际socket清理的原始cause丢失", err, observer.Errors())
	}
	if len(observer.owned) != 0 || len(guard.resources) != 0 {
		t.Fatal("失败Listen返回了仍然拥有的资源")
	}
	if err := wrapped.Close(); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(events, []string{"listen:failed", "close:socket"}) {
		t.Fatal("失败Listen调用了未启动的协议Close或重复关闭socket", events)
	}
}
