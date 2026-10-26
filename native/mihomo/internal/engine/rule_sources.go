package engine

import (
	"bufio"
	"errors"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/metacubex/mihomo/common/structure"
	"github.com/metacubex/mihomo/component/age"
	"github.com/metacubex/mihomo/config"
	P "github.com/metacubex/mihomo/constant/provider"
	RP "github.com/metacubex/mihomo/rules/provider"
	"go.yaml.in/yaml/v3"
)

type RuleReadError string

func (e RuleReadError) Error() string { return string(e) }

type ruleSource struct {
	Format  string   `provider:"format,omitempty"`
	Payload []string `provider:"payload,omitempty"`
}

func readRuleSources(raw *config.RawConfig) (map[string]ruleSource, error) {
	sources := make(map[string]ruleSource, len(raw.RuleProvider))
	decoder := structure.NewDecoder(structure.Option{TagName: "provider", WeaklyTypedInput: true})
	for name, mapping := range raw.RuleProvider {
		var source ruleSource
		if err := decoder.Decode(mapping, &source); err != nil {
			return nil, errors.New("invalid rule source metadata")
		}
		sources[name] = source
	}
	return sources, nil
}

// Only diagnostic ordering and configured intervals survive parsing. Neither
// this metadata nor its consumers retain a second copy of the running YAML.
type diagnosticSources struct {
	proxyProviders []string
	ruleProviders  []string
	proxies        []string
	proxyIntervals map[string]int
	ruleIntervals  map[string]int
}

func readDiagnosticSources(body []byte, raw *config.RawConfig) (diagnosticSources, error) {
	result := diagnosticSources{proxyIntervals: make(map[string]int), ruleIntervals: make(map[string]int)}
	plain, err := age.DecryptBytes(body)
	if err != nil {
		return result, err
	}
	var sections struct {
		Proxies yaml.Node `yaml:"proxy-providers"`
		Rules   yaml.Node `yaml:"rule-providers"`
	}
	if err := yaml.Unmarshal(plain, &sections); err != nil {
		return result, err
	}
	if result.proxyProviders, err = sourceMappingNames(&sections.Proxies); err != nil {
		return result, err
	}
	if result.ruleProviders, err = sourceMappingNames(&sections.Rules); err != nil {
		return result, err
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
				return result, errors.New("invalid provider interval metadata")
			}
			source.intervals[name] = fields.Interval
		}
	}
	for _, mapping := range raw.Proxy {
		var fields struct {
			Name string `provider:"name"`
		}
		if err := decoder.Decode(mapping, &fields); err != nil {
			return result, errors.New("invalid proxy name metadata")
		}
		result.proxies = append(result.proxies, fields.Name)
	}
	return result, nil
}

func sourceMappingNames(root *yaml.Node) ([]string, error) {
	var names []string
	seen := make(map[string]bool)
	var visit func(*yaml.Node, int) error
	visit = func(node *yaml.Node, depth int) error {
		if node == nil || node.Kind == 0 || node.Tag == "!!null" {
			return nil
		}
		if depth > 128 {
			return errors.New("provider source aliases exceed nesting limit")
		}
		switch node.Kind {
		case yaml.AliasNode:
			return visit(node.Alias, depth+1)
		case yaml.SequenceNode:
			for _, item := range node.Content {
				if err := visit(item, depth+1); err != nil {
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
					if err := visit(node.Content[i+1], depth+1); err != nil {
						return err
					}
				}
			}
		default:
			return errors.New("provider sources must be a mapping")
		}
		return nil
	}
	err := visit(root, 0)
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

// Read classical source text only from the loaded provider's Vehicle path.
func classicalSource(provider P.RuleProvider, source ruleSource, emit func(string) error) (string, error) {
	if provider.VehicleType() == P.Inline {
		for _, rule := range source.Payload {
			if err := emit(rule); err != nil {
				return "", err
			}
		}
		return "inline-source", nil
	}
	vehicle, ok := provider.(interface{ Vehicle() P.Vehicle })
	if !ok {
		return "", RuleReadError("sourceUnavailable")
	}
	path := vehicle.Vehicle().Path()
	file, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) && len(source.Payload) > 0 {
			for _, rule := range source.Payload {
				if err := emit(rule); err != nil {
					return "", err
				}
			}
			if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
				return "", RuleReadError("sourceChanged")
			}
			return "configuration-fallback-source", nil
		}
		return "", RuleReadError("sourceUnavailable")
	}
	defer file.Close()
	before, err := file.Stat()
	if err != nil || !before.Mode().IsRegular() {
		return "", RuleReadError("sourceInvalid")
	}
	if source.Format == "text" {
		reader := bufio.NewReader(file)
		for {
			line, readErr := reader.ReadString('\n')
			line = strings.TrimSpace(line)
			if line != "" && !strings.HasPrefix(line, "#") && !strings.HasPrefix(line, "//") {
				if err := emit(line); err != nil {
					return "", err
				}
			}
			if errors.Is(readErr, io.EOF) {
				break
			}
			if readErr != nil {
				return "", errors.New("rule provider cache read failed")
			}
		}
	} else if source.Format == "" || source.Format == "yaml" {
		var payload RP.RulePayload
		decoder := yaml.NewDecoder(file)
		if err := decoder.Decode(&payload); err != nil {
			return "", RuleReadError("sourceInvalid")
		}
		var extra any
		if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
			return "", RuleReadError("sourceInvalid")
		}
		items := payload.Payload
		if items == nil {
			items = payload.Rules
		}
		if items == nil {
			return "", RuleReadError("sourceInvalid")
		}
		for _, rule := range items {
			if err := emit(rule); err != nil {
				return "", err
			}
		}
	} else {
		return "", RuleReadError("sourceUnsupported")
	}
	after, err := os.Stat(path)
	if err != nil || !os.SameFile(before, after) || before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
		return "", RuleReadError("sourceChanged")
	}
	return "cache-source", nil
}
