package configinput

import (
	"bytes"
	"errors"
	"fmt"
	"io"

	"clashpseudo/native/internal/appcontract"

	"github.com/metacubex/mihomo/component/age"
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
	if len(body) > MaxConfigText {
		return nil, errors.New("main configuration exceeds text limit")
	}
	if len(overrides) == 0 {
		return body, nil
	}
	composed, _, err := ComposeWithProvenance(body, overrides, ConfigOrigin{})
	return composed, err
}

// ComposeWithProvenance tracks the actual merge nodes using metadata from the same
// immutable input. With zero overrides, return original bytes after origin inspection.
func ComposeWithProvenance(body []byte, overrides []Override, main ConfigOrigin) ([]byte, *Provenance, error) {
	if len(body) > MaxConfigText {
		return nil, nil, errors.New("main configuration exceeds text limit")
	}
	if (main.ID == "" && (main.Revision != 0 || main.Name != "")) || (main.ID != "" && main.Revision < 1) {
		return nil, nil, errors.New("invalid main configuration origin")
	}
	total := 0
	ids := make(map[string]bool, len(overrides))
	for _, part := range overrides {
		total += len(part.Body)
		if total > MaxConfigText || part.ID == "" || ids[part.ID] || part.Revision < 1 || (part.Mode != "prepend" && part.Mode != "replace") {
			return nil, nil, errors.New("invalid override input or text limit exceeded")
		}
		ids[part.ID] = true
	}
	plain, err := age.DecryptBytes(body)
	if err != nil || len(plain) > MaxConfigText {
		return nil, nil, errors.New("cannot decode main configuration")
	}
	base, err := configurationMapping(plain)
	if err != nil {
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
		base = mergeConfigNode(base, part, overrides[i].Mode, true, origins)
	}
	provenance := origins.project(base, priority)
	if len(overrides) == 0 {
		return body, provenance, nil
	}
	output := &limitedConfigBuffer{}
	encoder := yaml.NewEncoder(output)
	encoder.SetIndent(2)
	if err := encoder.Encode(base); err != nil {
		return nil, nil, errors.New("composed configuration exceeds limit or cannot be encoded")
	}
	if err := encoder.Close(); err != nil {
		return nil, nil, errors.New("cannot finish composed configuration")
	}
	return output.Bytes(), provenance, nil
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
	if err := decoder.Decode(&document); err != nil || len(document.Content) != 1 || document.Content[0].Kind != yaml.MappingNode {
		return nil, errors.New("expected one YAML mapping")
	}
	var extra yaml.Node
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, errors.New("multiple YAML documents are not supported")
	}
	root := document.Content[0]
	if err := checkConfigNodes(root, 0); err != nil {
		return nil, err
	}
	// The library resolves aliases and merge keys independently for each input.
	// Decode also rejects duplicate mapping keys and recursive aliases.
	var value map[string]any
	if err := root.Decode(&value); err != nil {
		return nil, errors.New("invalid YAML mapping or aliases")
	}
	var resolved yaml.Node
	if err := resolved.Encode(value); err != nil {
		return nil, errors.New("cannot normalize YAML mapping")
	}
	if err := checkConfigNodes(&resolved, 0); err != nil {
		return nil, err
	}
	preserveMappingOrder(&resolved, root, 0)
	for i := 0; i < len(resolved.Content); i += 2 {
		if namedConfigList(resolved.Content[i].Value) {
			if _, err := namedConfigItems(resolved.Content[i+1]); err != nil {
				return nil, err
			}
		}
	}
	return &resolved, nil
}

func checkConfigNodes(node *yaml.Node, depth int) error {
	if depth > 128 {
		return errors.New("configuration nesting exceeds limit")
	}
	if node.Kind == yaml.MappingNode {
		for i := 0; i < len(node.Content); i += 2 {
			key := node.Content[i]
			if key.Kind != yaml.ScalarNode || (key.Tag != "!!str" && key.Tag != "!!merge") {
				return errors.New("configuration keys must be strings")
			}
		}
	}
	for _, child := range node.Content {
		if err := checkConfigNodes(child, depth+1); err != nil {
			return err
		}
	}
	return nil
}

// Encoding decoded mappings sorts keys. Retain explicit source order for
// provider presentation; inherited merge-key fields follow explicit fields.
func preserveMappingOrder(node, source *yaml.Node, depth int) {
	if depth > 128 {
		return
	}
	if source.Kind == yaml.AliasNode {
		source = source.Alias
	}
	if source == nil || node.Kind != source.Kind {
		return
	}
	if node.Kind == yaml.SequenceNode {
		for i := range node.Content {
			if i < len(source.Content) {
				preserveMappingOrder(node.Content[i], source.Content[i], depth+1)
			}
		}
		return
	}
	if node.Kind != yaml.MappingNode {
		return
	}
	index := mappingIndex(node)
	ordered := make([]*yaml.Node, 0, len(node.Content))
	seen := make(map[string]bool)
	for i := 0; i < len(source.Content); i += 2 {
		key := source.Content[i]
		if position, exists := index[key.Value]; exists && !seen[key.Value] && key.Tag != "!!merge" {
			preserveMappingOrder(node.Content[position+1], source.Content[i+1], depth+1)
			ordered = append(ordered, node.Content[position], node.Content[position+1])
			seen[key.Value] = true
		}
	}
	for i := 0; i < len(node.Content); i += 2 {
		if !seen[node.Content[i].Value] {
			ordered = append(ordered, node.Content[i], node.Content[i+1])
		}
	}
	node.Content = ordered
}

func mappingIndex(node *yaml.Node) map[string]int {
	index := make(map[string]int, len(node.Content)/2)
	for i := 0; i < len(node.Content); i += 2 {
		index[node.Content[i].Value] = i
	}
	return index
}

func namedConfigList(key string) bool { return key == "proxies" || key == "proxy-groups" }

func namedConfigItems(node *yaml.Node) (map[string]int, error) {
	if node.Kind != yaml.SequenceNode {
		return nil, errors.New("named configuration list must be a sequence")
	}
	items := make(map[string]int, len(node.Content))
	for i, item := range node.Content {
		if item.Kind != yaml.MappingNode {
			return nil, errors.New("named configuration item must be a mapping")
		}
		position, exists := mappingIndex(item)["name"]
		if !exists {
			return nil, errors.New("named configuration item requires a name")
		}
		name := item.Content[position+1]
		if name.Tag != "!!str" || name.Value == "" {
			return nil, errors.New("configuration item name must be a nonempty string")
		}
		if _, exists := items[name.Value]; exists {
			return nil, errors.New("duplicate configuration name within one document")
		}
		items[name.Value] = i
	}
	return items, nil
}

func mergeConfigNode(base, part *yaml.Node, mode string, root bool, origins nodeOrigins) *yaml.Node {
	if base.Kind == yaml.MappingNode && part.Kind == yaml.MappingNode {
		result := *base
		result.Content = append([]*yaml.Node(nil), base.Content...)
		origins.inherit(&result, base)
		index := mappingIndex(base)
		for i := 0; i < len(part.Content); i += 2 {
			key, value := part.Content[i], part.Content[i+1]
			if position, exists := index[key.Value]; exists {
				if root && namedConfigList(key.Value) {
					result.Content[position+1] = mergeNamedConfigList(base.Content[position+1], value, mode, origins)
				} else {
					result.Content[position+1] = mergeConfigNode(base.Content[position+1], value, mode, false, origins)
				}
			} else {
				result.Content = append(result.Content, key, value)
			}
		}
		return &result
	}
	if base.Kind == yaml.SequenceNode && part.Kind == yaml.SequenceNode && mode == "prepend" {
		result := *part
		result.Content = append(append([]*yaml.Node(nil), part.Content...), base.Content...)
		// Empty prepend retains the existing value and its original source attribution.
		origins.inherit(&result, base)
		return &result
	}
	return part
}

func mergeNamedConfigList(base, part *yaml.Node, mode string, origins nodeOrigins) *yaml.Node {
	index, _ := namedConfigItems(base)
	items, _ := namedConfigItems(part)
	result := *base
	result.Content = make([]*yaml.Node, 0, len(base.Content)+len(part.Content))
	origins.inherit(&result, base)
	for _, item := range part.Content {
		name := item.Content[mappingIndex(item)["name"]+1].Value
		if _, exists := index[name]; !exists {
			result.Content = append(result.Content, item)
		}
	}
	for _, item := range base.Content {
		name := item.Content[mappingIndex(item)["name"]+1].Value
		if position, exists := items[name]; exists {
			item = mergeConfigNode(item, part.Content[position], mode, false, origins)
		}
		result.Content = append(result.Content, item)
	}
	return &result
}
