package androidnet

import (
	"encoding/json"
	"errors"
	"testing"

	"clashpseudo/native/internal/configinput"
)

func TestRuntimePlatformLimitsAreExplicitAndPreviewDoesNotEraseThem(t *testing.T) {
	for _, tc := range []struct{ yaml, field, reason string }{
		{"tun: {enable: false}", "tun.enable", "tunDisabled"},
		{"tun: {file-descriptor: 3}", "tun.file-descriptor", "externalFd"},
		{"tun: {device: custom}", "tun.device", "interfaceName"},
		{"tun: {auto-redirect: true}", "tun.auto-redirect", "autoRedirect"},
		{"tun: {auto-redirect-input-mark: 12}", "tun.auto-redirect-input-mark", "routingMark"},
		{"dns: {enable: false}\ntun: {dns-hijack: ['any:53']}", "tun.dns-hijack", "dnsHijackConflict"},
	} {
		t.Run(tc.field, func(t *testing.T) {
			body, presence, err := configinput.Decode([]byte(tc.yaml), "", "", true)
			if err != nil {
				t.Fatal(err)
			}
			raw := body
			var limit *PlatformError
			if err := PlatformRuntime(raw, presence); !errors.As(err, &limit) || limit.Field != tc.field || limit.Reason != tc.reason {
				t.Fatalf("wrong boundary error: %v", err)
			}
			var message map[string]any
			cause := errors.Join(limit, errors.New("cleanup https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"))
			if json.Unmarshal([]byte(limit.Message(cause.Error())), &message) != nil || message["id"] != "nativeConfigurationUnsupported" || message["detail"] != cause.Error() {
				t.Fatal("missing stable message or complete error")
			}
		})
	}
	body, presence, err := configinput.Decode([]byte("tun: {file-descriptor: 0, device: '', auto-redirect: false}\nrouting-mark: 0\nntp: {enable: false, write-to-system: true}\nsecret: unused\n"), "", "", true)
	if err != nil {
		t.Fatal(err)
	}
	raw := body
	if err := PlatformRuntime(raw, presence); err != nil {
		t.Fatalf("ineffective zero/disabled system request rejected: %v", err)
	}
}

func TestPublicNonTunServicesRemainAvailableToHub(t *testing.T) {
	for _, body := range []string{"external-controller: 127.0.0.1:9090", "ntp: {enable: true, write-to-system: true}", "redir-port: 7893\ntproxy-port: 7894", "external-ui-url: https://example.test/ui.zip"} {
		raw, p, err := configinput.Decode([]byte(body), "", "", true)
		if err != nil {
			t.Fatal(err)
		}
		if err = PlatformRuntime(raw, p); err != nil {
			t.Fatal("application rejected a public non-TUN feature", err)
		}
	}
}
