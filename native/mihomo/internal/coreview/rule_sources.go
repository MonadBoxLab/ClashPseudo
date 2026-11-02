package coreview

import (
	"errors"
	"fmt"
	"github.com/metacubex/mihomo/common/structure"
	"github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
	"sort"
)

// Only diagnostic ordering and configured intervals survive parsing. Neither
// this metadata nor its consumers retain a second copy of the running YAML.
type DiagnosticSources struct {
	proxyProviders []string
	ruleProviders  []string
	subRules       []string
	proxies        []string
	proxyIntervals map[string]int
	ruleIntervals  map[string]int
}

func ReadDiagnosticSources(body []byte, raw *config.RawConfig) (DiagnosticSources, error) {
	result := DiagnosticSources{proxyIntervals: make(map[string]int), ruleIntervals: make(map[string]int)}
	var err error
	var sections struct {
		Proxies  yaml.Node `yaml:"proxy-providers"`
		Rules    yaml.Node `yaml:"rule-providers"`
		SubRules yaml.Node `yaml:"sub-rules"`
	}
	if err := yaml.Unmarshal(body, &sections); err != nil {
		return result, err
	}
	var failures []error
	if result.proxyProviders, err = sourceMappingNames(&sections.Proxies); err != nil {
		failures = append(failures, fmt.Errorf("proxy provider order: %w", err))
	}
	if result.ruleProviders, err = sourceMappingNames(&sections.Rules); err != nil {
		failures = append(failures, fmt.Errorf("rule provider order: %w", err))
	}
	if result.subRules, err = sourceMappingNames(&sections.SubRules); err != nil {
		failures = append(failures, fmt.Errorf("sub-rules order: %w", err))
	}
	decoder := structure.NewDecoder(structure.Option{TagName: "provider", WeaklyTypedInput: true})
	for _, source := range []struct {
		values    map[string]map[string]any
		intervals map[string]int
	}{{raw.ProxyProvider, result.proxyIntervals}, {raw.RuleProvider, result.ruleIntervals}} {
		for name, mapping := range source.values {
			var fields struct {
				Interval int `provider:"interval,omitempty"`
			}
			if err := decoder.Decode(mapping, &fields); err != nil {
				failures = append(failures, fmt.Errorf("provider %q interval: %w", name, err))
				continue
			}
			source.intervals[name] = fields.Interval
		}
	}
	for _, mapping := range raw.Proxy {
		var fields struct {
			Name string `provider:"name"`
		}
		if err := decoder.Decode(mapping, &fields); err != nil {
			failures = append(failures, fmt.Errorf("proxy name: %w", err))
			continue
		}
		result.proxies = append(result.proxies, fields.Name)
	}
	return result, errors.Join(failures...)
}

func sourceMappingNames(root *yaml.Node) ([]string, error) {
	var names []string
	seen := make(map[string]bool)
	visited := make(map[*yaml.Node]bool)
	var visit func(*yaml.Node) error
	visit = func(node *yaml.Node) error {
		if node == nil || node.Kind == 0 || node.Tag == "!!null" || visited[node] {
			return nil
		}
		visited[node] = true
		switch node.Kind {
		case yaml.AliasNode:
			return visit(node.Alias)
		case yaml.SequenceNode:
			for _, item := range node.Content {
				if err := visit(item); err != nil {
					return err
				}
			}
		case yaml.MappingNode:
			// Explicit keys override inherited merge keys. Merge-sequence priority
			// follows YAML, while each source retains its own declaration order.
			for i := 0; i < len(node.Content); i += 2 {
				key := node.Content[i]
				if key.Tag != "!!merge" && !seen[key.Value] {
					names = append(names, key.Value)
					seen[key.Value] = true
				}
			}
			for i := 0; i < len(node.Content); i += 2 {
				if node.Content[i].Tag == "!!merge" {
					if err := visit(node.Content[i+1]); err != nil {
						return err
					}
				}
			}
		default:
			return errors.New("provider sources must be a mapping")
		}
		return nil
	}
	err := visit(root)
	return names, err
}

func declaredSourceOrder(names, declared []string) {
	positions := make(map[string]int, len(declared))
	for index, name := range declared {
		positions[name] = index
	}
	position := func(name string) int {
		if index, ok := positions[name]; ok {
			return index
		}
		return len(declared)
	}
	sort.Slice(names, func(i, j int) bool {
		left, right := position(names[i]), position(names[j])
		if left != right {
			return left < right
		}
		return names[i] < names[j]
	})
}
