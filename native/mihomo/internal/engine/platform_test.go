package engine

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/config"
)

func TestPlatformOwnsIngressWithoutChangingRules(t *testing.T) {
	body := validConfig + `port: 7890
mixed-port: 7891
allow-lan: true
external-controller: 0.0.0.0:9090
external-ui: ../../private
external-ui-url: http://127.0.0.1/ui.zip
ss-config: example
vmess-config: example
tun:
  enable: true
  auto-route: true
dns:
  listen: 0.0.0.0:53
ntp:
  enable: true
geo-auto-update: true
`
	raw, err := config.UnmarshalRawConfig([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	if err := configurePlatform(raw, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if raw.Port != 0 || raw.MixedPort != 0 || raw.AllowLan || raw.Tun.Enable ||
		raw.ExternalController != "" || raw.ExternalUI != "" || raw.DNS.Listen != "" ||
		raw.ShadowSocksConfig != "" || raw.VmessConfig != "" || raw.NTP.Enable || raw.GeoAutoUpdate {
		t.Fatal("configuration retained platform-owned ingress")
	}
	if len(raw.Rule) != 1 || raw.Rule[0] != "MATCH,DIRECT" {
		t.Fatal("routing policy was changed")
	}
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(body), func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	requireStop(t, &e)
}

func TestProviderCacheLocationIsApplicationOwned(t *testing.T) {
	raw, err := config.UnmarshalRawConfig([]byte(`proxy-providers:
  fixture:
    type: http
    url: http://127.0.0.1/provider
    path: ../configurations/configurations.json
`))
	if err != nil {
		t.Fatal(err)
	}
	if err := configurePlatform(raw, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if _, exists := raw.ProxyProvider["fixture"]["path"]; exists {
		t.Fatal("remote cache destination retained")
	}
}

func TestManagedResourcePathRejectsTraversalAndSymlinks(t *testing.T) {
	home := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(home, "link")); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"../outside", outside, "link/missing.yaml", ""} {
		if managedPath(home, path) {
			t.Fatalf("accepted external resource %q", path)
		}
	}
	if !managedPath(home, "providers/local.yaml") {
		t.Fatal("rejected application-owned path")
	}
}
