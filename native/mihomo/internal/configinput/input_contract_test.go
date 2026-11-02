package configinput_test

import (
	"bytes"
	"testing"

	"clashpseudo/native/internal/configinput"
	"github.com/metacubex/mihomo/component/age"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/tunnel"
)

func TestModePrecedenceAtPublicInputBoundary(t *testing.T) {
	for _, tc := range []struct {
		name, body, fallback, operation, want string
		present, invalid                      bool
	}{
		{"default", "{}", "", "", "rule", false, false},
		{"saved fallback", "{}", "direct", "", "direct", false, false},
		{"explicit wins", "mode: global", "direct", "", "global", true, false},
		{"unused invalid fallback", "mode: global", "invalid", "", "global", true, false},
		{"operation wins", "mode: global", "direct", "rule", "rule", true, false},
		{"invalid fallback", "{}", "invalid", "", "", false, true},
		{"invalid operation", "mode: global", "direct", "invalid", "", true, true},
		{"invalid explicit", "mode: invalid", "direct", "", "", true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input := []byte(tc.body)
			before := bytes.Clone(input)
			body, presence, err := configinput.RunningDefaults(input, tc.fallback, tc.operation)
			if !bytes.Equal(input, before) {
				t.Fatal("preparation changed saved source")
			}
			if tc.invalid {
				if err == nil || body != nil || presence != nil {
					t.Fatalf("invalid mode published an input: %v %v %v", body, presence, err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			raw := body
			if err != nil || raw.Mode.String() != tc.want {
				t.Fatalf("mode = %v, want %s; error = %v", raw, tc.want, err)
			}
			if presence.Has("mode") != tc.present || presence.Has("tun.stack") {
				t.Fatalf("defaults or operation override changed original presence: %v", presence)
			}
		})
	}
}

func TestModeValueParserDoesNotNormalizeInvalidInput(t *testing.T) {
	for value, want := range map[string]tunnel.TunnelMode{
		"rule": tunnel.Rule, "global": tunnel.Global, "direct": tunnel.Direct,
	} {
		if got, err := configinput.ParseMode(value); err != nil || got != want {
			t.Fatalf("ParseMode(%q) = %v, %v", value, got, err)
		}
	}
	for _, value := range []string{"", "Rule", " global", "direct\n", "unknown"} {
		if _, err := configinput.ParseMode(value); err == nil {
			t.Fatalf("accepted invalid mode %q", value)
		}
	}
	var absent configinput.Presence
	if absent.Has("mode") {
		t.Fatal("nil presence invented an explicit mode")
	}
}

func TestEncryptedMainUsesOnlyPublicDecodeBoundary(t *testing.T) {
	secret, public, err := age.GenX25519KeyPair()
	if err != nil {
		t.Fatal(err)
	}
	plain := []byte("\xef\xbb\xbf# synthetic encrypted input\r\nmode: global\r\ntun: {enable: false, mtu: 0}\r\ndns: {enable: false}\r\nrules: ['MATCH,DIRECT']\r\n")
	encrypted, err := age.EncryptBytes(plain, public)
	if err != nil {
		t.Fatal(err)
	}
	before := bytes.Clone(encrypted)
	origin := configinput.ConfigOrigin{ID: "encrypted-main", Revision: 3, Name: "测试主配置"}
	age.SetGlobalSecretKeys()
	t.Cleanup(func() { age.SetGlobalSecretKeys() })
	text, provenance, err := configinput.ComposeWithProvenance(encrypted, nil, origin)
	if err != nil || !bytes.Equal(text, before) || provenance != nil {
		t.Fatal("无插件路径改变了加密原字节")
	}
	_, original := config.UnmarshalRawConfig(encrypted)
	if original == nil {
		t.Fatal("测试正文未要求解密密钥")
	}
	if _, _, err := configinput.RunningDefaults(text, "", ""); err == nil || err.Error() != original.Error() {
		t.Fatalf("公开解码错误改变：%v，期望%v", err, original)
	}
	age.SetGlobalSecretKeys(secret)
	text, provenance, err = configinput.ComposeWithProvenance(encrypted, nil, origin)
	if err != nil || !bytes.Equal(text, before) || provenance != nil {
		t.Fatal("应用在Compose阶段解密了正文")
	}
	raw, presence, err := configinput.RunningDefaults(text, "direct", "")
	if err != nil || !presence.Has("$opaque") {
		t.Fatalf("公开解密未完成：%v", err)
	}
	if raw.Mode != tunnel.Global || raw.Tun.Enable || raw.Tun.MTU != 0 || raw.DNS.Enable || len(raw.Rule) != 1 || raw.Rule[0] != "MATCH,DIRECT" {
		t.Fatal("应用覆盖了无法读取字段来源的上游值")
	}
	raw, _, err = configinput.RunningDefaults(text, "", "rule")
	if err != nil || raw.Mode != tunnel.Rule {
		t.Fatal("显式operation未应用到同一RawConfig")
	}
	for _, mode := range []string{"prepend", "replace"} {
		_, _, err := configinput.ComposeWithProvenance(encrypted, []configinput.Override{{ID: "plugin", Revision: 1, Mode: mode, Body: "rules: ['DOMAIN,added.test,REJECT']\n"}}, origin)
		if err == nil {
			t.Fatal("插件合成越过了加密输入的公开解码边界")
		}
	}
	if !bytes.Equal(encrypted, before) {
		t.Fatal("保存的加密正文被修改")
	}
}

func TestDefaultsDoNotBecomeUserContributions(t *testing.T) {
	input := []byte("proxies: [{name: node, type: socks5, server: base.test, port: 1080}]\n")
	part := configinput.Override{ID: "plugin", Revision: 2, Name: "Loaded plugin", Mode: "replace",
		Body: "mode: direct\nproxies: [{name: node, server: plugin.test}]\n"}
	body, origin, err := configinput.ComposeWithProvenance(input, []configinput.Override{part},
		configinput.ConfigOrigin{ID: "main", Revision: 3, Name: "Loaded main"})
	if err != nil {
		t.Fatal(err)
	}
	definition := origin.Definition("proxies", "node")
	if definition == nil || len(definition.Contributors) != 2 {
		t.Fatalf("missing loaded field contributions: %+v", definition)
	}
	prepared, presence, err := configinput.RunningDefaults(body, "global", "")
	if err != nil {
		t.Fatal(err)
	}
	raw := prepared
	if err != nil || raw.Mode != tunnel.Direct || !presence.Has("mode") || presence.Has("tun.stack") {
		t.Fatalf("composition/default order changed: %+v %v %v", raw, presence, err)
	}
	for i, want := range []string{"plugin", "main"} {
		if got := definition.Contributors[i].ID; got != want {
			t.Fatalf("contributor %d = %q, want %q", i, got, want)
		}
	}
	if origin.Definition("tun", "stack") != nil || origin.Definition("proxies", "DIRECT") != nil {
		t.Fatal("application defaults or builtins acquired user provenance")
	}
}
