package engine

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/config"
	LC "github.com/metacubex/mihomo/listener/config"
)

func TestRuntimeConfigRedactsCredentialsWithoutMutatingCore(t *testing.T) {
	original := config.General{
		Inbound: config.Inbound{
			MixedPort:         1234,
			Authentication:    []string{"secret-auth"},
			ShadowSocksConfig: "secret-ss", VmessConfig: "secret-vmess",
			TuicServer: LC.TuicServer{
				Token:       []string{"secret-token"},
				Users:       map[string]string{"secret-user": "secret-password"},
				Certificate: "secret-cert", PrivateKey: "secret-key",
				ClientAuthCert: "secret-client-cert", EchKey: "secret-ech",
			},
		},
		GeoXUrl: config.GeoXUrl{
			GeoIp: "https://secret-host/path", GeoSite: "secret-source",
			Mmdb: "https://host/secret-path", ASN: "https://host/?secret-query",
		},
	}
	redacted := redactGeneral(original)
	data, err := json.Marshal(redacted)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "secret-") {
		t.Fatal("credential escaped redaction")
	}
	if redacted.MixedPort != 1234 || redacted.TuicServer.Enable {
		t.Fatal("ordinary runtime fields changed")
	}
	if original.Authentication[0] != "secret-auth" || original.TuicServer.Token[0] != "secret-token" || original.TuicServer.Users["secret-user"] != "secret-password" {
		t.Fatal("redaction mutated shared core data")
	}
	if redactPresent("") != "" || redactStrings(nil) != nil {
		t.Fatal("absent credentials were invented")
	}
}

func TestRuntimeConfigReadsLiveModeAndRequiresActiveCore(t *testing.T) {
	var e Engine
	if _, err := e.RuntimeConfig(); !errors.Is(err, ErrStopped) {
		t.Fatal(err)
	}
	if err := e.Prepare(t.TempDir(), []byte("rules:\n - MATCH,DIRECT\n"), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	for _, mode := range []string{"rule", "direct", "global"} {
		if err := e.SetMode(mode); err != nil {
			t.Fatal(err)
		}
		value, err := e.RuntimeConfig()
		if err != nil {
			t.Fatal(err)
		}
		var result map[string]any
		if err = json.Unmarshal([]byte(value), &result); err != nil {
			t.Fatal(err)
		}
		if result["mode"] != mode || result["mixed-port"] != float64(0) {
			t.Fatal("query did not return live platform-managed state")
		}
		if _, exists := result["rules"]; exists {
			t.Fatal("query pretended to contain full YAML")
		}
	}
	e.Cancel()
	if _, err := e.RuntimeConfig(); !errors.Is(err, ErrStopped) {
		t.Fatal(err)
	}
}
