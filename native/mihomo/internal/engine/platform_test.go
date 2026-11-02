package engine

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"

	A "github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	IN "github.com/metacubex/mihomo/listener/inbound"
)

func TestPlatformOwnsIngressWithoutChangingRules(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	port := occupied.Addr().(*net.TCPAddr).Port
	body := validConfig + "port: " + strings.Split(occupied.Addr().String(), ":")[1] + `
allow-lan: true
external-controller: 0.0.0.0:9090
external-ui: dashboard
external-ui-url: https://invalid.test/ui.zip
ss-config: example
vmess-config: example
tun: {enable: true, stack: gvisor, mtu: 1420}
dns: {listen: '127.0.0.1:53123'}
ntp: {enable: true}
`
	raw, err := config.UnmarshalRawConfig([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	if raw.Port != port || !raw.AllowLan || !raw.Tun.Enable || raw.Tun.Stack != C.TunGvisor || raw.Tun.MTU != 1420 || raw.ExternalController == "" || raw.ExternalUI == "" || raw.DNS.Listen == "" || !raw.NTP.Enable || raw.ShadowSocksConfig == "" || raw.VmessConfig == "" {
		t.Fatal("user configuration was erased to adapt Android")
	}
	if len(raw.Rule) != 1 || raw.Rule[0] != "MATCH,DIRECT" {
		t.Fatal("routing policy changed")
	}
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	if e.cfg.General.Port != port || e.cfg.Controller.ExternalController == "" || e.cfg.DNS.Listen == "" || !e.cfg.NTP.Enable {
		t.Fatal("preview replaced effective config with executor resource copy")
	}
	if len(e.ingress) != 0 || e.tun != nil {
		t.Fatal("preview opened external ingress")
	}
}

func TestRuntimeKeepsCoreSocketOptionsWithoutPrevalidation(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}

	for _, purpose := range []string{"PREVIEW", "RUNNING"} {
		t.Run(fmt.Sprint(purpose), func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			const body = `geo-auto-update: false
interface-name: fixture-missing
routing-mark: 12
proxies:
  - {name: options, type: direct, interface-name: fixture-missing, routing-mark: 12, tfo: true}
listeners:
  - {name: options-listener, type: http, listen: 127.0.0.1, port: 0, routing-mark: 12}
dns: {enable: true, listen: '127.0.0.1:0', listen-routing-mark: 12}
tun: {inet4-address: ['198.18.0.1/30']}
rules: ['MATCH,DIRECT']
`
			var e Engine
			if purpose == "PREVIEW" {
				if err := e.PrepareWithOptions(t.TempDir(), []byte(body), "", func(int) bool { return true }, PrepareOptions{Purpose: "PREVIEW"}); err != nil {
					t.Fatalf("socket options were rejected before actual use: %v", err)
				}
				defer requireStop(t, &e)
				if e.cfg.General.Interface != "fixture-missing" || e.cfg.General.RoutingMark != 12 {
					t.Fatal("global socket options changed")
				}
				info := e.cfg.Proxies["options"].Adapter().ProxyInfo()
				if info.Interface != "fixture-missing" || info.RoutingMark != 12 || !info.TFO {
					t.Fatalf("proxy socket options changed: %+v", info)
				}
				if option, ok := e.cfg.Listeners["options-listener"].Config().(*IN.HTTPOption); !ok || option == nil || option.RoutingMark != 12 || e.cfg.DNS.ListenRoutingMark != 12 {
					t.Fatal("listener or DNS socket options changed")
				}
				if e.tun != nil || len(e.listenerStates.Snapshot()) != 0 {
					t.Fatal("PREVIEW启动了外部listener")
				}
				requireStop(t, &e)
				return
			}
			lc := A.NewListenConfig()
			lc.SetRouteMark(12)
			baseline, original := lc.Listen(context.Background(), "tcp", "127.0.0.1:0")
			if original == nil {
				if err := baseline.Close(); err != nil {
					t.Fatal(err)
				}
			}
			err := e.PrepareWithOptions(t.TempDir(), []byte(body), "", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 1, Composition: "socket-options"})
			if original != nil {
				var socket *net.OpError
				if err == nil || !errors.As(err, &socket) || !strings.Contains(err.Error(), original.Error()) {
					t.Fatalf("实际socket错误被替换: %v; 原错误: %v", err, original)
				}
				if e.owner != nil || e.cfg != nil {
					t.Fatal("socket创建失败后仍持有context")
				}
			} else if err != nil {
				t.Fatal(err)
			}

		})
	}
}
