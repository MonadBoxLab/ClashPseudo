package configinput

import (
	"errors"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/tunnel"
	"go.yaml.in/yaml/v3"
)

// Presence records fields in the composed body, excluding application defaults from user input.
type Presence map[string]bool

func (p Presence) Has(path string) bool { return p[path] }

// Decode calls the upstream RawConfig decoder once, then applies defaults to the same object without re-encoding the body.
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

func fieldPresence(body []byte) Presence {
	present := Presence{}
	var document yaml.Node
	// Only plaintext provenance is read here. The upstream decoder handles encrypted body semantics and errors.
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

// ApplyDefaults preserves explicit false, zero, and null values, filling only the three defaults required by VPN.
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
