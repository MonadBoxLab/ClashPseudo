package engine

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"

	"clashpseudo/native/internal/configinput"
)

func TestPlatformOwnsIngressWithoutChangingRules(t *testing.T) {
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
	if err := configurePlatform(raw, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if raw.Port != port || !raw.AllowLan || !raw.Tun.Enable || raw.Tun.Stack != C.TunGvisor || raw.Tun.MTU != 1420 || raw.ExternalController == "" || raw.ExternalUI == "" || raw.DNS.Listen == "" || !raw.NTP.Enable || raw.ShadowSocksConfig == "" || raw.VmessConfig == "" {
		t.Fatal("user configuration was erased to adapt Android")
	}
	if len(raw.Rule) != 1 || raw.Rule[0] != "MATCH,DIRECT" {
		t.Fatal("routing policy changed")
	}
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
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

func TestProviderCacheLocationIsApplicationOwned(t *testing.T) {
	for _, path := range []string{"providers/explicit.yaml", ""} {
		body := "proxy-providers:\n  fixture:\n    type: http\n    url: https://invalid.test/provider\n"
		if path != "" {
			body += "    path: " + path + "\n"
		}
		raw, err := config.UnmarshalRawConfig([]byte(body))
		if err != nil {
			t.Fatal(err)
		}
		if err := configurePlatform(raw, t.TempDir()); err != nil {
			t.Fatal(err)
		}
		value, exists := raw.ProxyProvider["fixture"]["path"]
		if path == "" && exists {
			t.Fatal("missing HTTP path was needlessly materialized")
		}
		if path != "" && (!exists || value != path) {
			t.Fatal("explicit managed HTTP path was removed")
		}
	}
	for _, path := range []string{"../configurations/configurations.json", "cache.db", "tailscale/state", "GeoIP.dat"} {
		raw, _ := config.UnmarshalRawConfig([]byte("proxy-providers:\n  fixture:\n    type: http\n    url: https://invalid.test/provider\n    path: '" + path + "'\n"))
		if err := configurePlatform(raw, t.TempDir()); err == nil {
			t.Fatalf("accepted protected path %q", path)
		}
	}
	// The public parser derives cache paths for both absent and explicitly empty path
	// values.
	raw, _ := config.UnmarshalRawConfig([]byte("proxy-providers:\n  fixture:\n    type: http\n    url: https://invalid.test/provider\n    path: ''\n"))
	if err := configurePlatform(raw, t.TempDir()); err != nil {
		t.Fatalf("rejected HTTP provider whose empty path the parser derives: %v", err)
	}
}

func TestManagedResourcePathRejectsTraversalAndSymlinks(t *testing.T) {
	home, outside := t.TempDir(), t.TempDir()
	if err := os.Symlink(outside, filepath.Join(home, "link")); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(home, "identities"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(home, "identities"), filepath.Join(home, "inside-link")); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"../outside", outside, "link/missing.yaml", "inside-link/missing.yaml", ""} {
		if managedPath(home, path) {
			t.Fatalf("accepted external/protected resource %q", path)
		}
	}
	if !managedPath(home, "providers/local.yaml") {
		t.Fatal("rejected missing child under managed home")
	}
}

func TestProviderCannotReplaceCustomTailscaleIdentityOrDerivedCache(t *testing.T) {
	home := t.TempDir()
	for _, relative := range []string{"logins/account-a", "logins"} {
		raw, _ := config.UnmarshalRawConfig([]byte(`proxies:
  - {name: tail, type: tailscale, state-dir: logins/account-a}
proxy-providers:
  fixture: {type: http, url: 'https://invalid.test/nodes', path: '` + relative + `'}
`))
		if err := configurePlatform(raw, home); err == nil {
			t.Fatalf("provider overwrote identity path %s", relative)
		}
	}
	source := "https://invalid.test/nodes"
	derived := filepath.Join("proxies", filepath.Base(C.Path.GetPathByHash("proxies", source)))
	raw, _ := config.UnmarshalRawConfig([]byte("proxies:\n  - {name: tail, type: tailscale, state-dir: '" + derived + "'}\nproxy-providers:\n  fixture: {type: http, url: '" + source + "'}\n"))
	if err := configurePlatform(raw, home); err == nil {
		t.Fatal("derived HTTP path collided with an identity directory")
	}
}

func TestRuntimePlatformLimitsAreExplicitAndPreviewDoesNotEraseThem(t *testing.T) {
	for _, tc := range []struct{ yaml, field, reason string }{
		{"tun: {enable: false}", "tun.enable", "tunDisabled"},
		{"external-controller: 127.0.0.1:9090", "external-controller", "controllerUnavailable"},
		{"routing-mark: 12", "routing-mark", "routingMark"},
		{"tun: {file-descriptor: 3}", "tun.file-descriptor", "externalFd"},
		{"tun: {device: custom}", "tun.device", "interfaceName"},
		{"tun: {auto-redirect: true}", "tun.auto-redirect", "autoRedirect"},
		{"ntp: {enable: true, write-to-system: true}", "ntp.write-to-system", "systemClock"},
		{"dns: {enable: false}\ntun: {dns-hijack: ['any:53']}", "tun.dns-hijack", "dnsHijackConflict"},
	} {
		t.Run(tc.field, func(t *testing.T) {
			body, presence, err := configinput.RunningDefaults([]byte(tc.yaml), "", "")
			if err != nil {
				t.Fatal(err)
			}
			raw, _ := config.UnmarshalRawConfig(body)
			var limit *PlatformError
			if err := platformRuntime(raw, presence); !errors.As(err, &limit) || limit.Field != tc.field || limit.Reason != tc.reason {
				t.Fatalf("wrong boundary error: %v", err)
			}
			var message map[string]any
			if json.Unmarshal([]byte(limit.Message()), &message) != nil || message["id"] != "nativeConfigurationUnsupported" {
				t.Fatal("missing stable message")
			}
		})
	}
	body, presence, err := configinput.RunningDefaults([]byte("tun: {file-descriptor: 0, device: '', auto-redirect: false}\nrouting-mark: 0\nntp: {enable: false, write-to-system: true}\nsecret: unused\n"), "", "")
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := config.UnmarshalRawConfig(body)
	if err := platformRuntime(raw, presence); err != nil {
		t.Fatalf("ineffective zero/disabled system request rejected: %v", err)
	}
}
