package androidnet

import (
	"encoding/json"
	"errors"
	"slices"
	"testing"

	C "github.com/metacubex/mihomo/constant"

	"clashpseudo/native/internal/configinput"
)

func TestPlatformRuntimeIgnoresDesktopTunFields(t *testing.T) {
	body, presence, err := configinput.Decode([]byte(`
tun:
  enable: true
  stack: mixed
  dns-hijack:
    - any:53
  auto-route: true
  auto-redirect: true
  auto-detect-interface: true
  strict-route: true
dns:
  enable: true
`), "", "", true)
	if err != nil {
		t.Fatal(err)
	}
	ignored, err := PlatformRuntime(body, presence)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"tun.auto-redirect", "tun.strict-route", "tun.stack"} {
		if !slices.Contains(ignored, field) {
			t.Fatalf("missing ignored field %s in %v", field, ignored)
		}
	}
	if body.Tun.AutoRedirect || body.Tun.StrictRoute {
		t.Fatal("desktop routing fields were left enabled")
	}
	if !body.Tun.Enable || body.Tun.Stack != C.TunMips {
		t.Fatalf("mixed stack was not remapped: enable=%v stack=%v", body.Tun.Enable, body.Tun.Stack)
	}
}

func TestPlatformRuntimeClearsUnsupportedValues(t *testing.T) {
	for _, tc := range []struct {
		yaml  string
		field string
	}{
		{"tun: {enable: false}", "tun.enable"},
		{"tun: {file-descriptor: 3}", "tun.file-descriptor"},
		{"tun: {device: custom}", "tun.device"},
		{"tun: {auto-redirect: true}", "tun.auto-redirect"},
		{"tun: {auto-redirect-input-mark: 12}", "tun.auto-redirect-input-mark"},
		{"tun: {stack: mixed}", "tun.stack"},
		{"tun: {stack: system}", "tun.stack"},
	} {
		t.Run(tc.field, func(t *testing.T) {
			raw, presence, err := configinput.Decode([]byte(tc.yaml), "", "", true)
			if err != nil {
				t.Fatal(err)
			}
			ignored, err := PlatformRuntime(raw, presence)
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Contains(ignored, tc.field) {
				t.Fatalf("expected %s in %v", tc.field, ignored)
			}
			switch tc.field {
			case "tun.enable":
				if !raw.Tun.Enable {
					t.Fatal("tun.enable was not forced on")
				}
			case "tun.file-descriptor":
				if raw.Tun.FileDescriptor != 0 {
					t.Fatal("file-descriptor was not cleared")
				}
			case "tun.device":
				if raw.Tun.Device != "" {
					t.Fatal("device was not cleared")
				}
			case "tun.auto-redirect":
				if raw.Tun.AutoRedirect {
					t.Fatal("auto-redirect was not cleared")
				}
			case "tun.auto-redirect-input-mark":
				if raw.Tun.AutoRedirectInputMark != 0 {
					t.Fatal("auto-redirect-input-mark was not cleared")
				}
			case "tun.stack":
				if raw.Tun.Stack != C.TunMips {
					t.Fatalf("stack was not remapped to mips: %v", raw.Tun.Stack)
				}
			}
		})
	}
	for _, stack := range []string{"gvisor", "mips"} {
		raw, presence, err := configinput.Decode([]byte("tun: {stack: "+stack+"}\n"), "", "", true)
		if err != nil {
			t.Fatal(err)
		}
		ignored, err := PlatformRuntime(raw, presence)
		if err != nil {
			t.Fatal(err)
		}
		if slices.Contains(ignored, "tun.stack") {
			t.Fatalf("%s stack should remain: %v", stack, ignored)
		}
	}
	raw, presence, err := configinput.Decode([]byte("tun: {file-descriptor: 0, device: '', auto-redirect: false}\nrouting-mark: 0\nntp: {enable: false, write-to-system: true}\nsecret: unused\n"), "", "", true)
	if err != nil {
		t.Fatal(err)
	}
	ignored, err := PlatformRuntime(raw, presence)
	if err != nil {
		t.Fatalf("ineffective zero/disabled system request rejected: %v", err)
	}
	if len(ignored) != 0 {
		t.Fatalf("zero values should not be listed as ignored: %v", ignored)
	}
}

func TestPlatformRuntimeRejectsDNSConflictWithoutClearingInput(t *testing.T) {
	for _, body := range []string{
		"dns: {enable: false}",
		"dns: {enable: false}\ntun: {dns-hijack: ['any:53']}",
		"dns: {enable: false}\ntun: {dns-hijack: [], inet6-address: ['fd00::1/126']}",
	} {
		t.Run(body, func(t *testing.T) {
			raw, presence, err := configinput.Decode([]byte(body), "", "", true)
			if err != nil {
				t.Fatal(err)
			}
			hijack := slices.Clone(raw.Tun.DNSHijack)
			addresses := slices.Clone(raw.Tun.Inet6Address)
			ignored, err := PlatformRuntime(raw, presence)
			var limit *PlatformError
			if !errors.As(err, &limit) || limit.Field != "tun.dns-hijack" || limit.Reason != "dnsHijackConflict" || ignored != nil {
				t.Fatalf("wrong DNS conflict result: ignored=%v err=%v", ignored, err)
			}
			if raw.DNS.Enable || !slices.Equal(raw.Tun.DNSHijack, hijack) || !slices.Equal(raw.Tun.Inet6Address, addresses) {
				t.Fatal("DNS conflict silently rewrote the requested configuration")
			}
			cause := errors.Join(limit, errors.New("cleanup https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"))
			var message map[string]any
			if json.Unmarshal([]byte(limit.Message(cause.Error())), &message) != nil || message["id"] != "nativeConfigurationUnsupported" || message["detail"] != cause.Error() {
				t.Fatal("missing stable message or complete error")
			}
			raw.DNS.Enable = true
			if ignored, err := PlatformRuntime(raw, presence); err != nil || len(ignored) != 0 {
				t.Fatalf("enabled DNS was rejected or ignored: ignored=%v err=%v", ignored, err)
			}
		})
	}
}

func TestPlatformRuntimeRejectsInvalidValues(t *testing.T) {
	raw, presence, err := configinput.Decode([]byte("tun: {mtu: 70000}"), "", "", true)
	if err != nil {
		t.Fatal(err)
	}
	ignored, err := PlatformRuntime(raw, presence)
	var limit *PlatformError
	if !errors.As(err, &limit) || limit.Field != "tun.mtu" || limit.Reason != "invalidMtu" || ignored != nil {
		t.Fatalf("wrong invalid mtu result: ignored=%v err=%v", ignored, err)
	}
}

func TestPublicNonTunServicesRemainAvailableToHub(t *testing.T) {
	for _, body := range []string{"external-controller: 127.0.0.1:9090", "ntp: {enable: true, write-to-system: true}", "redir-port: 7893\ntproxy-port: 7894", "external-ui-url: https://example.test/ui.zip"} {
		raw, p, err := configinput.Decode([]byte(body), "", "", true)
		if err != nil {
			t.Fatal(err)
		}
		ignored, err := PlatformRuntime(raw, p)
		if err != nil {
			t.Fatal("application rejected a public non-TUN feature", err)
		}
		if len(ignored) != 0 {
			t.Fatalf("unexpected ignored fields: %v", ignored)
		}
	}
}
