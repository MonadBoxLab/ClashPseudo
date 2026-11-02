package engine

import (
	"encoding/json"
	"errors"
	"reflect"
	"testing"

	"github.com/metacubex/mihomo/hub/executor"
)

func TestRuntimeConfigPreservesPublicFeedbackWithoutSubstitutingRequestedInbound(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	input := []byte(`authentication: ["user:secret-auth"]
geox-url:
  geoip: https://user:password@example.test/path?token=secret
  geosite: https://example.test/site?token=secret
  mmdb: https://example.test/country?token=secret
  asn: https://example.test/asn?token=secret
rules: ["MATCH,DIRECT"]
`)
	if err := e.Prepare(t.TempDir(), input, "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	// A parsed request is not evidence that the public listener table reports it.
	e.cfg.General.Inbound.MixedPort = 31337
	before, err := json.Marshal(e.cfg.General)
	if err != nil {
		t.Fatal(err)
	}
	expected, err := json.Marshal(executor.GetGeneral())
	if err != nil {
		t.Fatal(err)
	}
	value, err := e.RuntimeConfig()
	if err != nil {
		t.Fatal(err)
	}
	var public, actual map[string]any
	if err := json.Unmarshal(expected, &public); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(value), &actual); err != nil {
		t.Fatal(err)
	}
	general, ok := actual["general"].(map[string]any)
	if !ok {
		t.Fatal("缺少公开general反馈", actual)
	}
	for key, want := range public {
		if !reflect.DeepEqual(general[key], want) {
			t.Fatalf("public feedback changed at %s", key)
		}
	}
	if general["mixed-port"] == float64(31337) {
		t.Fatal("requested inbound substituted for actual feedback")
	}
	requested, ok := actual["requested"].(map[string]any)
	if !ok || requested["mixed-port"] != float64(31337) {
		t.Fatal("缺少独立保存的请求值", actual)
	}
	platform, ok := actual["actual"].(map[string]any)
	if !ok || platform["tun"] != nil || len(platform["listeners"].([]any)) != 0 {
		t.Fatal("preparation fabricated active platform objects", actual)
	}
	after, err := json.Marshal(e.cfg.General)
	if err != nil || string(before) != string(after) {
		t.Fatal("reading feedback mutated the input")
	}
}

func TestRuntimeConfigReadsLiveModeAndRequiresActiveCore(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	if _, err := e.RuntimeConfig(); !errors.Is(err, ErrStopped) {
		t.Fatal(err)
	}
	if err := e.Prepare(t.TempDir(), []byte("rules:\n - MATCH,DIRECT\n"), "rule", func(int) bool { return true }); err != nil {
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
		general, ok := result["general"].(map[string]any)
		if !ok || general["mode"] != mode || general["mixed-port"] != float64(0) {
			t.Fatal("query did not return live platform-managed state", result)
		}
		if _, exists := general["rules"]; exists {
			t.Fatal("query pretended to contain full YAML")
		}
	}
	e.Cancel()
	if _, err := e.RuntimeConfig(); !errors.Is(err, ErrStopped) {
		t.Fatal(err)
	}
}
