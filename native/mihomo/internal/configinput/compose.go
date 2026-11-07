package configinput

import (
	"bytes"
	"errors"
	"fmt"
	"io"

	"clashpseudo/native/internal/appcontract"

	"go.yaml.in/yaml/v3"
)

const MaxConfigText = appcontract.ConfigurationTextBytes

type Override struct {
	ID       string `json:"id"`
	Revision int    `json:"revision"`
	Name     string `json:"name,omitempty"`
	Role     string `json:"role,omitempty"`
	Mode     string `json:"mode"`
	Body     string `json:"body"`
}

// Compose preserves saved text; overrides are ordered highest priority first.
func Compose(body []byte, overrides []Override) ([]byte, error) {
	composed, _, err := ComposeWithProvenance(body, overrides, ConfigOrigin{})
	return composed, err
}

// ComposeWithProvenance tracks the nodes changed by the requested composition.
// Source metadata never determines whether the core may read an unchanged input.
func ComposeWithProvenance(body []byte, overrides []Override, main ConfigOrigin) ([]byte, *Provenance, error) {
	if len(body) > MaxConfigText {
		return nil, nil, errors.New("main configuration exceeds text limit")
	}
	total := 0
	for i, part := range overrides {
		if len(part.Body) > MaxConfigText-total {
			return nil, nil, errors.New("enabled override text exceeds limit")
		}
		total += len(part.Body)
		if part.Mode != "prepend" && part.Mode != "replace" {
			return nil, nil, fmt.Errorf("override %d: unknown composition mode %q", i+1, part.Mode)
		}
	}
	base, err := configurationMapping(body)
	if err != nil {
		if len(overrides) == 0 {
			return body, nil, nil
		}
		return nil, nil, fmt.Errorf("main configuration: %w", err)
	}
	origins := make(nodeOrigins)
	mainSource := SourceOrigin{Kind: "config", ID: main.ID, Revision: main.Revision, Name: main.Name}
	origins.capture(base, mainSource, "")
	priority := map[SourceOrigin]int{mainSource: len(overrides)}
	for i := len(overrides) - 1; i >= 0; i-- {
		part, err := configurationMapping([]byte(overrides[i].Body))
		if err != nil {
			return nil, nil, fmt.Errorf("override %d: %w", i+1, err)
		}
		source := SourceOrigin{Kind: "plugin", ID: overrides[i].ID, Revision: overrides[i].Revision, Name: overrides[i].Name, Role: overrides[i].Role}
		priority[source] = i
		origins.capture(part, source, "")
		base, err = mergeConfigNode(base, part, overrides[i].Mode, true, origins, make(map[configMergePair]bool))
		if err != nil {
			return nil, nil, fmt.Errorf("override %d: %w", i+1, err)
		}
	}
	provenance := origins.project(base, priority)
	if len(overrides) == 0 {
		return body, provenance, nil
	}
	output, err := encodeConfigNode(base)
	if err != nil {
		return nil, nil, err
	}
	return output, provenance, nil
}

type limitedConfigBuffer struct{ bytes.Buffer }

func (b *limitedConfigBuffer) Write(p []byte) (int, error) {
	if len(p) > MaxConfigText-b.Len() {
		return 0, errors.New("configuration text limit exceeded")
	}
	return b.Buffer.Write(p)
}

func configurationMapping(body []byte) (*yaml.Node, error) {
	decoder := yaml.NewDecoder(bytes.NewReader(body))
	var document yaml.Node
	if err := decoder.Decode(&document); err != nil {
		return nil, err
	}
	if len(document.Content) != 1 || document.Content[0].Kind != yaml.MappingNode {
		return nil, errors.New("expected one YAML mapping for composition")
	}
	var extra yaml.Node
	if err := decoder.Decode(&extra); err != io.EOF {
		if err != nil {
			return nil, err
		}
		return nil, errors.New("multiple YAML documents cannot be composed")
	}
	return document.Content[0], nil
}

func configValue(node *yaml.Node) *yaml.Node {
	if node.Kind == yaml.AliasNode {
		return node.Alias
	}
	return node
}

// Read merge fields only for a mapping being used by the requested operation.
// Unrelated values and invalid merge operands remain for the public parser.
func configMapping(node *yaml.Node) *yaml.Node {
	resolved := make(map[*yaml.Node]*yaml.Node)
	var mapping func(*yaml.Node) (*yaml.Node, bool)
	mapping = func(node *yaml.Node) (*yaml.Node, bool) {
		node = configValue(node)
		if node.Kind != yaml.MappingNode {
			return node, false
		}
		if previous, exists := resolved[node]; exists {
			if previous == nil {
				return node, false
			}
			return previous, true
		}
		resolved[node] = nil
		result := *node
		result.Content = nil
		seen := make(map[string]bool)
		var merges []*yaml.Node
		for i := 0; i < len(node.Content); i += 2 {
			key, value := node.Content[i], node.Content[i+1]
			if key.Tag == "!!merge" {
				merges = append(merges, value)
				continue
			}
			result.Content = append(result.Content, key, value)
			seen[key.Tag+"\x00"+key.Value] = true
		}
		if len(merges) == 0 {
			resolved[node] = node
			return node, true
		}
		for _, merge := range merges {
			operands := []*yaml.Node{merge}
			if value := configValue(merge); value.Kind == yaml.SequenceNode {
				operands = value.Content
			}
			for _, operand := range operands {
				inherited, ok := mapping(operand)
				if !ok {
					return node, false
				}
				for i := 0; i < len(inherited.Content); i += 2 {
					key := inherited.Content[i]
					id := key.Tag + "\x00" + key.Value
					if !seen[id] {
						result.Content = append(result.Content, key, inherited.Content[i+1])
						seen[id] = true
					}
				}
			}
		}
		result.Anchor = ""
		resolved[node] = &result
		return &result, true
	}
	result, _ := mapping(node)
	return result
}

// Preserve reference targets even when an edit removes or replaces their original
// anchor location. Separate input documents never borrow one another's anchors.
func encodeConfigNode(root *yaml.Node) ([]byte, error) {
	anchors := make(map[*yaml.Node]string)
	var emit func(*yaml.Node) *yaml.Node
	emit = func(node *yaml.Node) *yaml.Node {
		if node.Kind == yaml.AliasNode {
			if name, exists := anchors[node.Alias]; exists {
				result := *node
				result.Value = name
				return &result
			}
			return emit(node.Alias)
		}
		result := *node
		if node.Anchor != "" {
			if name, exists := anchors[node]; exists {
				return &yaml.Node{Kind: yaml.AliasNode, Value: name, Alias: node}
			}
			name := fmt.Sprintf("input_%d", len(anchors))
			anchors[node] = name
			result.Anchor = name
		}
		result.Content = make([]*yaml.Node, len(node.Content))
		for i, child := range node.Content {
			result.Content[i] = emit(child)
		}
		return &result
	}
	output := &limitedConfigBuffer{}
	encoder := yaml.NewEncoder(output)
	encoder.SetIndent(2)
	if err := encoder.Encode(emit(root)); err != nil {
		return nil, err
	}
	if err := encoder.Close(); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

func mappingIndex(node *yaml.Node) map[string]int {
	index := make(map[string]int, len(node.Content)/2)
	if node.Kind == yaml.MappingNode {
		for i := 0; i < len(node.Content); i += 2 {
			if key := node.Content[i]; key.Kind == yaml.ScalarNode && key.Tag == "!!str" {
				index[key.Value] = i
			}
		}
	}
	return index
}

func namedConfigList(key string) bool { return key == "proxies" || key == "proxy-groups" }

func namedConfigName(node *yaml.Node) (string, bool) {
	node = configMapping(node)
	position, exists := mappingIndex(node)["name"]
	if !exists {
		return "", false
	}
	var name any
	if err := node.Content[position+1].Decode(&name); err != nil {
		return "", false
	}
	value, ok := name.(string)
	return value, ok && value != ""
}

func namedConfigItems(node *yaml.Node) map[string]int {
	items := make(map[string]int)
	for i, item := range node.Content {
		if name, ok := namedConfigName(item); ok {
			if _, exists := items[name]; exists {
				items[name] = -1 // Ambiguous rows remain separate for the core to parse.
			} else {
				items[name] = i
			}
		}
	}
	return items
}

type configMergePair struct{ base, part *yaml.Node }

func mergeConfigNode(base, part *yaml.Node, mode string, root bool, origins nodeOrigins, active map[configMergePair]bool) (*yaml.Node, error) {
	// Track original targets, not the temporary mappings expanded from merge keys.
	pair := configMergePair{configValue(base), configValue(part)}
	baseView, partView := configMapping(base), configMapping(part)
	origins.inherit(baseView, base)
	origins.inherit(partView, part)
	if baseView.Kind == yaml.MappingNode && partView.Kind == yaml.MappingNode {
		if active[pair] {
			return nil, errors.New("cyclic mapping merge")
		}
		active[pair] = true
		defer delete(active, pair)
		base, part = baseView, partView
		result := *base
		result.Anchor = ""
		result.Content = append([]*yaml.Node(nil), base.Content...)
		origins.inherit(&result, base)
		index := make(map[string]int, len(base.Content)/2)
		keyID := func(key *yaml.Node) string { return key.Tag + "\x00" + key.Value }
		for i := 0; i < len(base.Content); i += 2 {
			if key := base.Content[i]; key.Kind == yaml.ScalarNode {
				index[keyID(key)] = i
			}
		}
		for i := 0; i < len(part.Content); i += 2 {
			key, value := part.Content[i], part.Content[i+1]
			position, exists := index[keyID(key)]
			if exists && key.Kind == yaml.ScalarNode {
				var err error
				if root && namedConfigList(key.Value) && configValue(base.Content[position+1]).Kind == yaml.SequenceNode && configValue(value).Kind == yaml.SequenceNode {
					result.Content[position+1], err = mergeNamedConfigList(configValue(base.Content[position+1]), configValue(value), mode, origins, active)
				} else {
					result.Content[position+1], err = mergeConfigNode(base.Content[position+1], value, mode, false, origins, active)
				}
				if err != nil {
					return nil, err
				}
			} else {
				result.Content = append(result.Content, key, value)
			}
		}
		return &result, nil
	}
	if baseView.Kind == yaml.SequenceNode && partView.Kind == yaml.SequenceNode && mode == "prepend" {
		result := *partView
		result.Anchor = ""
		result.Content = append(append([]*yaml.Node(nil), partView.Content...), baseView.Content...)
		origins.inherit(&result, base)
		return &result, nil
	}
	return part, nil
}

func mergeNamedConfigList(base, part *yaml.Node, mode string, origins nodeOrigins, active map[configMergePair]bool) (*yaml.Node, error) {
	index, items := namedConfigItems(base), namedConfigItems(part)
	result := *base
	result.Anchor = ""
	result.Content = make([]*yaml.Node, 0, len(base.Content)+len(part.Content))
	origins.inherit(&result, base)
	for _, item := range part.Content {
		name, named := namedConfigName(item)
		position, exists := index[name]
		if !named || !exists || position < 0 || items[name] < 0 {
			result.Content = append(result.Content, item)
		}
	}
	for _, item := range base.Content {
		name, named := namedConfigName(item)
		if position, exists := items[name]; named && exists && position >= 0 && index[name] >= 0 {
			var err error
			item, err = mergeConfigNode(item, part.Content[position], mode, false, origins, active)
			if err != nil {
				return nil, err
			}
		}
		result.Content = append(result.Content, item)
	}
	return &result, nil
}
