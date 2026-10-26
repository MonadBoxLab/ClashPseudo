package engine

import (
	"bytes"
	"context"
	cryptorand "crypto/rand"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/common/structure"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/transport/tlsmirror"
	quic "github.com/metacubex/quic-go"
	"github.com/metacubex/quic-go/quicvarint"
	quictls "github.com/metacubex/tls"
	"go.yaml.in/yaml/v3"

	"clashpseudo/native/internal/configinput"
)

type proxyFormContractFixture struct {
	ID          string         `json:"id"`
	Definition  map[string]any `json:"definition"`
	YAML        string         `json:"yaml"`
	ExpectError string         `json:"expect_error"`
}

func proxyFormFixtures(t *testing.T) []proxyFormContractFixture {
	t.Helper()
	// Resolve checked-in input from the Go package workspace; real widgets consume the
	// same input.
	root := filepath.Clean(filepath.Join("..", "..", "..", ".."))
	data, err := os.ReadFile(filepath.Join(root, "test", "fixtures", "form_contracts", "proxies.json"))
	if err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var fixtures []proxyFormContractFixture
	if err := decoder.Decode(&fixtures); err != nil {
		t.Fatal(err)
	}
	var resolve func(any) any
	resolve = func(value any) any {
		switch value := value.(type) {
		case json.Number:
			integer, err := value.Int64()
			if err != nil {
				t.Fatal("test JSON integer is outside signed64; a uint64 decimal string must be explicit", err)
			}
			return integer
		case string:
			if !strings.HasPrefix(value, "@fixture:") {
				return value
			}
			if value != "@fixture:icon_tls/cert.pem" && value != "@fixture:icon_tls/key.pem" {
				t.Fatal("unsupported self-authored fixture reference")
			}
			data, err := os.ReadFile(filepath.Join(root, "test", "fixtures", "icon_tls", strings.TrimPrefix(value, "@fixture:icon_tls/")))
			if err != nil {
				t.Fatal(err)
			}
			return string(data)
		case map[string]any:
			for key, child := range value {
				value[key] = resolve(child)
			}
		case []any:
			for i, child := range value {
				value[i] = resolve(child)
			}
		}
		return value
	}
	seen := make(map[string]bool)
	for i := range fixtures {
		fixture := &fixtures[i]
		if fixture.ID == "" || seen[fixture.ID] || fixture.YAML == "" {
			t.Fatal("missing/duplicated contract identity or missing exact YamlEditor output")
		}
		seen[fixture.ID] = true
		fixture.Definition = resolve(fixture.Definition).(map[string]any)
	}
	return fixtures
}

type proxyFormNoNetwork struct{ attempts atomic.Int64 }

func (d *proxyFormNoNetwork) DialContext(context.Context, string, string) (net.Conn, error) {
	d.attempts.Add(1)
	return nil, errors.New("network is disabled for form construction contracts")
}

func (d *proxyFormNoNetwork) ListenPacket(context.Context, string, string, netip.AddrPort) (net.PacketConn, error) {
	d.attempts.Add(1)
	return nil, errors.New("network is disabled for form construction contracts")
}

var proxyFormAdapterTypes = map[string]C.AdapterType{
	"http": C.Http, "socks5": C.Socks5, "ssh": C.Ssh, "masque": C.Masque,
	"ss": C.Shadowsocks, "ssr": C.ShadowsocksR, "vmess": C.Vmess, "vless": C.Vless,
	"snell": C.Snell, "trojan": C.Trojan, "hysteria": C.Hysteria, "hysteria2": C.Hysteria2,
	"tuic": C.Tuic, "shadowquic": C.ShadowQuic, "gost-relay": C.GostRelay, "mieru": C.Mieru,
	"anytls": C.AnyTLS, "sudoku": C.Sudoku, "trusttunnel": C.TrustTunnel,
	"wireguard": C.WireGuard, "openvpn": C.OpenVPN, "zerotier": C.ZeroTier,
	"easytier": C.EasyTier, "tailscale": C.Tailscale,
	"direct": C.Direct, "dns": C.Dns, "reject": C.Reject, "rematch": C.Rematch,
}

func proxyFormComposedDefinition(t *testing.T, fixture proxyFormContractFixture, mode string) map[string]any {
	t.Helper()
	var fragment map[string]any
	if err := yaml.Unmarshal([]byte(fixture.YAML), &fragment); err != nil {
		t.Fatalf("actual YamlEditor output is rejected by native YAML: %v", err)
	}
	text, err := configinput.Compose([]byte("proxies: [{name: lower, type: direct}]\nrules: [\"MATCH,DIRECT\"]\n"), []configinput.Override{
		{ID: "local-custom-fixture", Revision: 1, Mode: mode, Body: fixture.YAML},
	})
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]any
	if err := yaml.Unmarshal(text, &root); err != nil {
		t.Fatal(err)
	}
	proxies, ok := root["proxies"].([]any)
	if !ok || len(proxies) != 2 {
		t.Fatal("local definition was dropped or replaced the unrelated lower definition")
	}
	var definition map[string]any
	for _, proxy := range proxies {
		candidate, ok := proxy.(map[string]any)
		if ok && candidate["name"] == fixture.Definition["name"] {
			definition = candidate
		}
	}
	got, err := json.Marshal(definition)
	if err != nil {
		t.Fatal(err)
	}
	want, err := json.Marshal(fixture.Definition)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("Compose changed the actual GUI/YamlEditor definition, scalar types, or explicit empty/false values")
	}
	proxyFormScalarKinds(t, definition, fixture.Definition)
	return definition
}

func proxyFormScalarKinds(t *testing.T, actual, expected any) {
	t.Helper()
	switch expected := expected.(type) {
	case map[string]any:
		mapping, ok := actual.(map[string]any)
		if !ok {
			t.Fatal("native GUI mapping changed kind")
		}
		for key, value := range expected {
			proxyFormScalarKinds(t, mapping[key], value)
		}
	case []any:
		list, ok := actual.([]any)
		if !ok || len(list) != len(expected) {
			t.Fatal("native GUI list changed kind/length")
		}
		for i, value := range expected {
			proxyFormScalarKinds(t, list[i], value)
		}
	case int64:
		// Verify native YAML integer storage through the complete conversion path.
		switch actual.(type) {
		case int, int64, uint64:
		default:
			t.Fatalf("exact GUI integer became %T", actual)
		}
	case string:
		if _, ok := actual.(string); !ok {
			t.Fatal("GUI string changed scalar kind")
		}
	case bool:
		if _, ok := actual.(bool); !ok {
			t.Fatal("GUI bool changed scalar kind")
		}
	case nil:
		if actual != nil {
			t.Fatal("GUI null changed scalar kind")
		}
	default:
		t.Fatalf("unsupported fixture scalar kind %T", expected)
	}
}

func TestProxyFormSlashScannerRegression(t *testing.T) {
	// Require the exact minimal yaml_edit escape emitted by the actual OpenVPN form.
	var value map[string]any
	if err := yaml.Unmarshal([]byte("value: \"a\\/b\\nlast\"\n"), &value); err == nil || !strings.Contains(err.Error(), "unknown escape character") {
		t.Fatalf("native scanner premise changed: %v", err)
	}
	for _, fixture := range proxyFormFixtures(t) {
		if fixture.ID != "openvpn" {
			continue
		}
		if err := yaml.Unmarshal([]byte(fixture.YAML), &value); err != nil {
			t.Fatalf("real widget/YamlEditor PEM still fails native scanner: %v", err)
		}
		return
	}
	t.Fatal("missing real OpenVPN widget regression")
}

func TestProxyFormFlowPlainScannerRegression(t *testing.T) {
	for _, bad := range []string{
		`{url: https://fixture.invalid/provider?token=synthetic}`,
		`{allowed-ips: [::/0]}`,
	} {
		var value map[string]any
		if err := yaml.Unmarshal([]byte(bad), &value); err == nil {
			t.Fatal("fixed native flow-plain scanner premise changed")
		}
	}
	seen := 0
	for _, fixture := range proxyFormFixtures(t) {
		if fixture.ID != "http-query-and-backslashes" && fixture.ID != "wireguard-peer-fields" {
			continue
		}
		seen++
		var value map[string]any
		if err := yaml.Unmarshal([]byte(fixture.YAML), &value); err != nil {
			t.Fatalf("real GUI/YamlEditor flow scalar still fails native scanner: %v", err)
		}
	}
	if seen != 2 {
		t.Fatal("missing actual query/IPv6 GUI regression output")
	}
}

func TestProxyFormPublicParserContract(t *testing.T) {
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(t.TempDir())
	t.Cleanup(func() { C.SetHomeDir(oldHome) })
	seenSuccess := make(map[string]bool)
	for _, fixture := range proxyFormFixtures(t) {
		for _, mode := range []string{"prepend", "replace"} {
			t.Run(fixture.ID+"/"+mode, func(t *testing.T) {
				definition := proxyFormComposedDefinition(t, fixture, mode)
				kind, ok := definition["type"].(string)
				if !ok {
					t.Fatal("GUI did not emit an original type string")
				}
				blocked := &proxyFormNoNetwork{}
				t.Cleanup(func() {
					if blocked.attempts.Load() != 0 {
						t.Error("construction unexpectedly attempted network IO")
					}
				})
				proxy, err := adapter.ParseProxy(definition, adapter.WithDialerForAPI(blocked))
				if fixture.ExpectError != "" {
					if err == nil {
						_ = proxy.Close()
						t.Fatal("invalid protocol-specific input unexpectedly constructed")
					}
					if !strings.Contains(err.Error(), fixture.ExpectError) {
						t.Fatalf("parser did not reach the intended public field: %v", err)
					}
					return
				}
				if err != nil {
					t.Fatalf("public %s constructor rejected the real GUI output: %v", kind, err)
				}
				t.Cleanup(func() {
					if err := proxy.Close(); err != nil {
						t.Errorf("public %s Close failed: %v", kind, err)
					}
					if blocked.attempts.Load() != 0 {
						t.Error("construction unexpectedly attempted network IO")
					}
				})
				if proxy.Name() != definition["name"] || proxy.Type() != proxyFormAdapterTypes[kind] {
					t.Fatal("parser returned a different original protocol/name")
				}
				seenSuccess[kind] = true
			})
		}
	}
	if len(seenSuccess) != 28 {
		t.Fatalf("only %d of 28 original types constructed successfully", len(seenSuccess))
	}
}

// Validate limits against actual public consumers.
func TestProxyFormExactTimeSpecFromActualGUI(t *testing.T) {
	for _, fixture := range proxyFormFixtures(t) {
		if fixture.ID != "vmess-tlsmirror-all-fields" {
			continue
		}
		definition := proxyFormComposedDefinition(t, fixture, "prepend")
		decoder := structure.NewDecoder(structure.Option{TagName: "proxy", WeaklyTypedInput: true, KeyReplacer: structure.DefaultKeyReplacer})
		var option outbound.VmessOption
		if err := decoder.Decode(definition, &option); err != nil {
			t.Fatal(err)
		}
		config := option.TLSMirrorOpts.Build()
		if config == nil || config.EmbeddedTrafficGenerator == nil || len(config.EmbeddedTrafficGenerator.Steps) != 1 {
			t.Fatal("actual GUI nested TLSMirror options did not reach their consumer")
		}
		if _, err := tlsmirror.DecodePrimaryKey(config.PrimaryKey); err != nil {
			t.Fatal(err)
		}
		original := cryptorand.Reader
		t.Cleanup(func() { cryptorand.Reader = original })
		for _, spec := range []tlsmirror.TimeSpec{config.DeferInstanceDerivedWrite, config.EmbeddedTrafficGenerator.Steps[0].WaitTime} {
			if spec.BaseNanoseconds != 0 || spec.UniformRandomMultiplierNanoseconds != 1<<63 {
				t.Fatal("actual GUI decimal uint64 changed before the TimeSpec consumer")
			}
			cryptorand.Reader = bytes.NewReader([]byte{0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff})
			duration, err := spec.Duration()
			cryptorand.Reader = original
			if err != nil || duration != time.Duration(1<<63-1) {
				t.Fatalf("exact GUI unsigned multiplier failed the actual duration consumer: %v %v", duration, err)
			}
		}
		return
	}
	t.Fatal("missing actual GUI TimeSpec boundary fixture")
}

func TestProxyFormTimeSpecConsumerLimits(t *testing.T) {
	const max = uint64(1<<63 - 1)
	base := tlsmirror.TimeSpec{BaseNanoseconds: max}
	if duration, err := base.Duration(); err != nil || duration != time.Duration(max) {
		t.Fatalf("maximum signed duration changed: %v %v", duration, err)
	}
	if duration, err := (tlsmirror.TimeSpec{BaseNanoseconds: 1 << 63}).Duration(); err != nil || duration >= 0 {
		t.Fatalf("the rejected base boundary no longer demonstrates native duration wrap: %v %v", duration, err)
	}
	// Run serially with a deterministic highest admissible crypto/rand.Reader draw, then
	// immediately restore the original reader.
	original := cryptorand.Reader
	t.Cleanup(func() { cryptorand.Reader = original })
	for _, tc := range []struct {
		name             string
		base, multiplier uint64
		draw             []byte
		want             time.Duration
	}{
		{"exact unsigned multiplier", 0, 1 << 63, []byte{0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, time.Duration(max)},
		{"unsafe combined pair", max, 2, []byte{1}, time.Duration(-1 << 63)},
		{"unsafe uint64 multiplier", 0, ^uint64(0), []byte{0x80, 0, 0, 0, 0, 0, 0, 0}, time.Duration(-1 << 63)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cryptorand.Reader = bytes.NewReader(tc.draw)
			duration, err := (tlsmirror.TimeSpec{BaseNanoseconds: tc.base, UniformRandomMultiplierNanoseconds: tc.multiplier}).Duration()
			cryptorand.Reader = original
			if err != nil || duration != tc.want {
				t.Fatalf("actual TimeSpec consumer did not preserve the exact expected boundary: %v %v", duration, err)
			}
		})
	}
}

func TestProxyFormQUICWindowConsumerLimits(t *testing.T) {
	for _, value := range []uint64{0, quicvarint.Max, 1 << 63, ^uint64(0)} {
		config := &quic.Config{
			InitialStreamReceiveWindow: value, MaxStreamReceiveWindow: value,
			InitialConnectionReceiveWindow: value, MaxConnectionReceiveWindow: value,
			Versions: []quic.Version{0},
		}
		// Public Listen validates config before touching any socket. An explicitly
		// invalid version stops there, after the real maximum-window clamps.
		transport := &quic.Transport{}
		if listener, err := transport.Listen(&quictls.Config{}, config); err == nil || !strings.Contains(err.Error(), "invalid QUIC version") {
			if listener != nil {
				_ = listener.Close()
			}
			t.Fatalf("controlled offline validation did not stop before transport initialization: %v", err)
		}
		want := value
		if want > quicvarint.Max {
			want = quicvarint.Max
		}
		if config.MaxStreamReceiveWindow != want || config.MaxConnectionReceiveWindow != want {
			t.Fatal("fixed QUIC consumer no longer applies the documented max-window boundary")
		}
		if config.InitialStreamReceiveWindow != value || config.InitialConnectionReceiveWindow != value {
			t.Fatal("initial windows were unexpectedly validated/clamped; review their transport-parameter consumer")
		}
		// Exercise all four exact uint64 Hysteria2 window values through the public QUIC
		// varint consumer.
		panicked := false
		func() {
			defer func() { panicked = recover() != nil }()
			_ = quicvarint.Append(nil, config.InitialStreamReceiveWindow)
			_ = quicvarint.Append(nil, config.InitialConnectionReceiveWindow)
		}()
		if panicked != (value > quicvarint.Max) {
			t.Fatal("public QUIC wire varint consumer boundary changed")
		}
	}
}

func TestProxyFormZeroTierTraceConsumerLimits(t *testing.T) {
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(t.TempDir())
	t.Cleanup(func() { C.SetHomeDir(oldHome) })
	var base map[string]any
	for _, fixture := range proxyFormFixtures(t) {
		if fixture.ID == "zerotier" {
			base = fixture.Definition
		}
	}
	if base == nil {
		t.Fatal("missing real ZeroTier form fixture")
	}
	for _, tc := range []struct {
		value    any
		valid    bool
		boundary string
	}{
		{int64(0), true, ""}, {int64(30), true, ""}, {int64(31), false, "remote trace level"},
		{"9223372036854775808", false, "remote trace level"},
		{"18446744073709551615", false, "remote trace level"},
		{"18446744073709551616", false, ""},
	} {
		definition := make(map[string]any, len(base))
		for key, value := range base {
			definition[key] = value
		}
		definition["remote-trace-level"] = tc.value
		blocked := &proxyFormNoNetwork{}
		proxy, err := adapter.ParseProxy(definition, adapter.WithDialerForAPI(blocked))
		if tc.valid {
			if err != nil {
				t.Fatalf("valid trace boundary rejected: %v", err)
			}
			if err := proxy.Close(); err != nil {
				t.Fatal(err)
			}
		} else {
			if err == nil {
				_ = proxy.Close()
				t.Fatal("unsafe trace boundary constructed")
			}
			if tc.boundary != "" && !strings.Contains(err.Error(), tc.boundary) {
				t.Fatalf("wrong native consumer rejected trace boundary: %v", err)
			}
		}
		if blocked.attempts.Load() != 0 {
			t.Fatal("trace boundary attempted network IO")
		}
	}
}

// Test-only public Option ABI coverage for the explicitly written forms and real
// widget inputs. Internal proxy:"-" fields are outside the form field set.
func TestProxyFormGostRejectsNonPublicMode(t *testing.T) {
	for _, fixture := range proxyFormFixtures(t) {
		if fixture.ID != "ss-plugin-gost-plugin" {
			continue
		}
		definition := proxyFormComposedDefinition(t, fixture, "prepend")
		options := make(map[string]any)
		for key, value := range definition["plugin-opts"].(map[string]any) {
			options[key] = value
		}
		options["mode"] = "http2"
		definition["plugin-opts"] = options
		blocked := &proxyFormNoNetwork{}
		proxy, err := adapter.ParseProxy(definition, adapter.WithDialerForAPI(blocked))
		if err == nil {
			_ = proxy.Close()
			t.Fatal("non-public Gost HTTP2 mode unexpectedly constructed")
		}
		if !strings.Contains(err.Error(), "obfs mode error: http2") {
			t.Fatalf("wrong native branch rejected the non-public mode: %v", err)
		}
		if blocked.attempts.Load() != 0 {
			t.Fatal("non-public mode attempted network IO")
		}
		return
	}
	t.Fatal("missing actual public Gost websocket fixture")
}

func TestProxyFormDynamicPluginAndMuxFieldsExercised(t *testing.T) {
	// Enumerate public configuration keys for the fixed internal obfs structs; include
	// production fields only.
	fixtures := make(map[string]proxyFormContractFixture)
	for _, fixture := range proxyFormFixtures(t) {
		fixtures[fixture.ID] = fixture
	}
	websocket := "mode host path tls ech-opts.enable ech-opts.config ech-opts.query-server-name fingerprint certificate private-key headers skip-cert-verify name-cert-verify mux"
	shadow := "password host fingerprint certificate private-key skip-cert-verify name-cert-verify version alpn"
	restls := "password host version-hint restls-script fingerprint skip-cert-verify name-cert-verify"
	jls := "host username password alpn"
	for _, tc := range []struct{ fixture, prefix, fields string }{
		{"ss-plugin-obfs", "plugin-opts", "mode host"},
		{"ss-plugin-obfs-tls", "plugin-opts", "mode host"},
		{"ss-plugin-v2ray-plugin", "plugin-opts", websocket + " v2ray-http-upgrade v2ray-http-upgrade-fast-open"},
		{"ss-plugin-gost-plugin", "plugin-opts", websocket},
		{"ss-plugin-shadow-tls", "plugin-opts", shadow},
		{"ss-plugin-restls", "plugin-opts", restls},
		{"ss-plugin-jls", "plugin-opts", jls},
		{"ss-plugin-kcptun", "plugin-opts", "key crypt mode conn autoexpire scavengettl mtu ratelimit sndwnd rcvwnd datashard parityshard dscp nocomp acknodelay nodelay interval resend nc sockbuf smuxver smuxbuf framesize streambuf keepalive"},
		{"snell-obfs-tls", "obfs-opts", "mode host"},
		{"snell-obfs-http", "obfs-opts", "mode host"},
		{"snell-obfs-shadow-tls", "obfs-opts", "mode " + shadow},
		{"snell-obfs-restls", "obfs-opts", "mode " + restls},
		{"snell-obfs-jls", "obfs-opts", "mode " + jls},
		{"ss-smux-brutal", "smux", "enabled protocol max-connections min-streams max-streams padding statistic only-tcp brutal-opts.enabled brutal-opts.up brutal-opts.down"},
		{"ss-smux-yamux", "smux", "enabled protocol max-connections min-streams max-streams padding statistic only-tcp brutal-opts.enabled brutal-opts.up brutal-opts.down"},
		{"ss-smux-h2mux", "smux", "enabled protocol max-connections min-streams max-streams padding statistic only-tcp brutal-opts.enabled brutal-opts.up brutal-opts.down"},
	} {
		fixture, ok := fixtures[tc.fixture]
		if !ok {
			t.Errorf("missing actual GUI plugin branch %s", tc.fixture)
			continue
		}
		for _, field := range strings.Fields(tc.fields) {
			var value any = fixture.Definition
			for _, key := range strings.Split(tc.prefix+"."+field, ".") {
				mapping, ok := value.(map[string]any)
				if !ok {
					t.Errorf("%s missing public branch field %s", tc.fixture, field)
					break
				}
				value, ok = mapping[key]
				if !ok {
					t.Errorf("%s missing public branch field %s", tc.fixture, field)
					break
				}
			}
		}
		if mapping, ok := fixture.Definition[tc.prefix].(map[string]any); ok {
			if _, exists := mapping["force-tls12"]; exists {
				t.Error("test-only force-tls12 must not be exposed by GUI")
			}
		}
	}
}

func TestProxyFormAllPublicOptionFieldsExercised(t *testing.T) {
	options := map[string]any{
		"http": outbound.HttpOption{}, "socks5": outbound.Socks5Option{}, "ssh": outbound.SshOption{},
		"masque": outbound.MasqueOption{}, "ss": outbound.ShadowSocksOption{}, "ssr": outbound.ShadowSocksROption{},
		"vmess": outbound.VmessOption{}, "vless": outbound.VlessOption{}, "snell": outbound.SnellOption{},
		"trojan": outbound.TrojanOption{}, "hysteria": outbound.HysteriaOption{}, "hysteria2": outbound.Hysteria2Option{},
		"tuic": outbound.TuicOption{}, "shadowquic": outbound.ShadowQuicOption{}, "gost-relay": outbound.GostRelayOption{},
		"mieru": outbound.MieruOption{}, "anytls": outbound.AnyTLSOption{}, "sudoku": outbound.SudokuOption{},
		"trusttunnel": outbound.TrustTunnelOption{}, "wireguard": outbound.WireGuardOption{}, "openvpn": outbound.OpenVPNOption{},
		"zerotier": outbound.ZeroTierOption{}, "easytier": outbound.EasyTierOption{}, "tailscale": outbound.TailscaleOption{},
		"direct": outbound.DirectOption{}, "dns": outbound.DnsOption{}, "reject": outbound.RejectOption{}, "rematch": outbound.RematchOption{},
	}
	paths := make(map[string]map[string]bool)
	var visitValue func(map[string]bool, string, any)
	visitValue = func(seen map[string]bool, path string, value any) {
		seen[path] = true
		switch value := value.(type) {
		case map[string]any:
			for key, child := range value {
				name := key
				if path != "" {
					name = path + "." + key
				}
				visitValue(seen, name, child)
			}
		case []any:
			for _, child := range value {
				visitValue(seen, path+"[]", child)
			}
		}
	}
	for _, fixture := range proxyFormFixtures(t) {
		kind := fixture.Definition["type"].(string)
		if paths[kind] == nil {
			paths[kind] = make(map[string]bool)
		}
		visitValue(paths[kind], "", fixture.Definition)
	}
	var fields func(reflect.Type, string) []string
	fields = func(kind reflect.Type, path string) []string {
		for kind.Kind() == reflect.Pointer {
			kind = kind.Elem()
		}
		if kind.Kind() == reflect.Slice && kind.Elem().Kind() == reflect.Struct {
			return fields(kind.Elem(), path+"[]")
		}
		if kind.Kind() != reflect.Struct {
			return []string{path}
		}
		var result []string
		for i := 0; i < kind.NumField(); i++ {
			field := kind.Field(i)
			if field.PkgPath != "" {
				continue
			}
			name := strings.Split(field.Tag.Get("proxy"), ",")[0]
			if name == "-" {
				continue
			}
			if field.Anonymous && name == "" {
				result = append(result, fields(field.Type, path)...)
				continue
			}
			if name == "" {
				continue
			}
			if path != "" {
				name = path + "." + name
			}
			result = append(result, fields(field.Type, name)...)
		}
		return result
	}
	for kind, option := range options {
		var missing []string
		for _, path := range fields(reflect.TypeOf(option), "") {
			if !paths[kind][path] {
				missing = append(missing, path)
			}
		}
		sort.Strings(missing)
		if len(missing) != 0 {
			t.Errorf("%s public fields not exercised by real form fixtures: %s", kind, strings.Join(missing, ", "))
		}
	}
}
