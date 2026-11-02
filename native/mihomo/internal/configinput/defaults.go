package configinput

import (
	"errors"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/tunnel"
	"go.yaml.in/yaml/v3"
)

// Presence记录合成正文中的字段，不把应用缺省值记作用户输入。
type Presence map[string]bool

func (p Presence) Has(path string) bool { return p[path] }

// Decode仅调用一次上游RawConfig解码；补缺省直接修改同一对象，不重新编码正文。
func Decode(body []byte, fallback, operation string, vpn bool) (*config.RawConfig, Presence, error) {
	raw, err := config.UnmarshalRawConfig(body)
	if err != nil {
		return nil, nil, err
	}
	present := fieldPresence(body)
	if err := ApplyDefaults(raw, present, fallback, operation, vpn); err != nil {
		return nil, nil, err
	}
	return raw, present, nil
}

// RunningDefaults保留VPN准备的调用入口，返回实际交给ParseRawConfig的对象。
func RunningDefaults(body []byte, fallback, operation string) (*config.RawConfig, Presence, error) {
	return Decode(body, fallback, operation, true)
}

func fieldPresence(body []byte) Presence {
	present := Presence{}
	var document yaml.Node
	// 这里只读取明文来源。加密正文的语义与错误由上游解码器处理。
	if yaml.Unmarshal(body, &document) != nil || len(document.Content) == 0 {
		present["$opaque"] = true
		return present
	}
	root := configMapping(document.Content[0])
	if root.Kind != yaml.MappingNode {
		present["$opaque"] = true
		return present
	}
	for i := 0; i < len(root.Content); i += 2 {
		name, value := root.Content[i].Value, root.Content[i+1]
		present[name] = true
		switch name {
		case "tun", "dns", "geox-url":
			fields := configMapping(value)
			if fields.Kind == yaml.MappingNode {
				present[name+".$mapping"] = true
				for j := 0; j < len(fields.Content); j += 2 {
					present[name+"."+fields.Content[j].Value] = true
				}
			}
		}
	}
	return present
}

// ApplyDefaults保留显式false、0和null，只补VPN实际需要的三个缺省。
func ApplyDefaults(raw *config.RawConfig, p Presence, fallback, operation string, vpn bool) error {
	if operation != "" || (!p.Has("$opaque") && !p.Has("mode") && fallback != "") {
		mode := operation
		if mode == "" {
			mode = fallback
		}
		parsed, err := ParseMode(mode)
		if err != nil {
			return err
		}
		raw.Mode = parsed
	}
	missing := func(section, field string) bool {
		return !p.Has("$opaque") && !p.Has(section+"."+field) && (!p.Has(section) || p.Has(section+".$mapping"))
	}
	if vpn {
		if missing("tun", "enable") {
			raw.Tun.Enable = true
		}
		if missing("tun", "mtu") {
			raw.Tun.MTU = 1500
		}
		if missing("dns", "enable") {
			raw.DNS.Enable = true
		}
	}
	return nil
}

func ParseMode(value string) (tunnel.TunnelMode, error) {
	switch value {
	case "rule":
		return tunnel.Rule, nil
	case "global":
		return tunnel.Global, nil
	case "direct":
		return tunnel.Direct, nil
	default:
		return tunnel.Rule, errors.New("invalid tunnel mode")
	}
}
