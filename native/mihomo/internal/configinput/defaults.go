package configinput

import (
	"errors"
	"fmt"
	"strings"

	"github.com/metacubex/mihomo/component/age"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/tunnel"
	"go.yaml.in/yaml/v3"
)

// Capture field presence after Compose and before RawConfig defaults; the public
// mihomo parser validates values.
type Presence map[string]bool

func (p Presence) Has(path string) bool { return p[path] }

// RunningDefaults adds only application-required fields that are absent.
func RunningDefaults(body []byte, fallback, operation string) ([]byte, Presence, error) {
	plain, err := age.DecryptBytes(body)
	if err != nil {
		return nil, nil, err
	}
	root, err := configurationMapping(plain)
	if err != nil {
		return nil, nil, err
	}
	present := Presence{}
	var visit func(*yaml.Node, string)
	visit = func(node *yaml.Node, path string) {
		if node.Kind != yaml.MappingNode {
			return
		}
		for i := 0; i < len(node.Content); i += 2 {
			name := node.Content[i].Value
			if path != "" {
				name = path + "." + name
			}
			present[name] = true
			visit(node.Content[i+1], name)
		}
	}
	visit(root, "")
	put := func(path string, value any) error {
		parts := strings.Split(path, ".")
		node := root
		for _, key := range parts[:len(parts)-1] {
			var child *yaml.Node
			for i := 0; i < len(node.Content); i += 2 {
				if node.Content[i].Value == key {
					child = node.Content[i+1]
					break
				}
			}
			if child == nil {
				child = &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
				node.Content = append(node.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, child)
			}
			if child.Kind != yaml.MappingNode {
				return fmt.Errorf("%s must be a mapping", key)
			}
			node = child
		}
		var encoded yaml.Node
		if err := encoded.Encode(value); err != nil {
			return err
		}
		key := parts[len(parts)-1]
		for i := 0; i < len(node.Content); i += 2 {
			if node.Content[i].Value == key {
				node.Content[i+1] = &encoded
				return nil
			}
		}
		node.Content = append(node.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, &encoded)
		return nil
	}
	defaults := []struct {
		path  string
		value any
	}{
		{"tun.enable", true}, {"tun.stack", "mips"}, {"tun.mtu", 1500},
		{"tun.auto-route", true}, {"dns.enable", true}, {"profile.store-selected", false},
	}
	missing := func(path string) bool {
		if present.Has(path) {
			return false
		}
		node := root
		parts := strings.Split(path, ".")
		for _, key := range parts[:len(parts)-1] {
			position, exists := mappingIndex(node)[key]
			if !exists {
				return true
			}
			node = node.Content[position+1]
			// Pass explicit null containers and other original value types through to the
			// public parser.
			if node.Kind != yaml.MappingNode {
				return false
			}
		}
		return true
	}
	for _, d := range defaults {
		if missing(d.path) {
			if err := put(d.path, d.value); err != nil {
				return nil, nil, err
			}
		}
	}
	if operation != "" || !present.Has("mode") {
		mode := operation
		if mode == "" {
			mode = fallback
		}
		if mode == "" {
			mode = "rule"
		}
		if _, err := ParseMode(mode); err != nil {
			return nil, nil, err
		}
		if err := put("mode", mode); err != nil {
			return nil, nil, err
		}
	}
	encode := func() ([]byte, error) {
		output := &limitedConfigBuffer{}
		encoder := yaml.NewEncoder(output)
		encoder.SetIndent(2)
		if err := encoder.Encode(root); err != nil {
			return nil, err
		}
		if err := encoder.Close(); err != nil {
			return nil, err
		}
		return output.Bytes(), nil
	}
	output, err := encode()
	if err != nil {
		return nil, nil, err
	}
	// Unmarshal once to inspect the *effective* enable flag, including an explicit
	// false. The same public parser is used below for the formal RawConfig.
	raw, err := config.UnmarshalRawConfig(output)
	if err != nil {
		return nil, nil, err
	}
	if missing("tun.dns-hijack") && !raw.DNS.Enable {
		if err = put("tun.dns-hijack", []string{}); err != nil {
			return nil, nil, err
		}
		output, err = encode()
	}
	return output, present, err
}

// ParseMode accepts the three routing modes supported by this app.
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
