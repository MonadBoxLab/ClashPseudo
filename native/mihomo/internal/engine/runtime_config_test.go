package engine

import (
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/hub/executor"
	"go.yaml.in/yaml/v3"
)

func TestRuntimeConfigMatchesPublicGeneral(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	input := []byte(`authentication: ["fixture:example-password"]
global-ua: "false"
geox-url:
  geoip: https://fixture:example@example.test/path?token=example
  geosite: https://example.test/site?token=example
  mmdb: https://example.test/country?token=example
  asn: https://example.test/asn?token=example
rules: ["MATCH,DIRECT"]
`)
	if err := e.Prepare(t.TempDir(), input, "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
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
	var parsed any
	if err := yaml.Unmarshal([]byte(value), &parsed); err != nil {
		t.Fatal(err)
	}
	converted, err := json.Marshal(parsed)
	if err != nil {
		t.Fatal(err)
	}
	var want, got map[string]any
	if err := json.Unmarshal(expected, &want); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(converted, &got); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatal("YAML 与公开运行配置不同")
	}
	if got["global-ua"] != "false" {
		t.Fatal("字符串类型发生变化")
	}
	if auth, ok := got["authentication"].([]any); !ok || len(auth) != 1 || auth[0] != "fixture" {
		t.Fatal("认证字段与公开运行配置不同")
	}
	if got["mixed-port"] == float64(31337) {
		t.Fatal("请求端口替代了公开运行状态")
	}
	if _, ok := got["requested"]; ok {
		t.Fatal("运行配置包含应用包装")
	}
	if _, ok := got["actual"]; ok {
		t.Fatal("运行配置包含平台包装")
	}
	if !strings.Contains(value, "\ntun:\n") {
		t.Fatal("TUN 配置未按 YAML 展示")
	}
	after, err := json.Marshal(e.cfg.General)
	if err != nil || string(before) != string(after) {
		t.Fatal("读取改变了请求配置")
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
		if err = yaml.Unmarshal([]byte(value), &result); err != nil {
			t.Fatal(err)
		}
		if result["mode"] != mode || result["mixed-port"] != 0 {
			t.Fatal("读取没有返回实时运行状态")
		}
		if _, exists := result["rules"]; exists {
			t.Fatal("运行配置不是完整配置文件")
		}
	}
	e.Cancel()
	if _, err := e.RuntimeConfig(); !errors.Is(err, ErrStopped) {
		t.Fatal(err)
	}
}
