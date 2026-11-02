package configinput

import (
	"sort"
	"strconv"
	"strings"

	"go.yaml.in/yaml/v3"
)

// ConfigOrigin describes the main input captured for this composition; zero denotes
// absent identity.
type ConfigOrigin struct {
	ID       string `json:"id,omitempty"`
	Revision int    `json:"revision,omitempty"`
	Name     string `json:"name,omitempty"`
}

// SourceOrigin contains identity and display metadata; Role is read from the loaded
// plugin's role field.
type SourceOrigin struct {
	Kind     string `json:"kind"`
	ID       string `json:"id,omitempty"`
	Revision int    `json:"revision,omitempty"`
	Name     string `json:"name,omitempty"`
	Role     string `json:"role,omitempty"`
}

// fieldOrigin.Path is a JSON Pointer into the source mapping; sequence indexes
// belong to that original source.
type fieldOrigin struct {
	SourceOrigin
	Path string `json:"path"`
}

type SourceContribution struct {
	SourceOrigin
	// Path identifies the original definition or rule.
	Path string `json:"path"`
}

// DefinitionProvenance lists surviving inputs in priority order, with main last; leaf
// attribution is temporary merge bookkeeping.
type DefinitionProvenance struct {
	Contributors []SourceContribution `json:"contributors"`
}

// Provenance is the immutable, composition-local projection of the same YAML
// nodes Compose actually merged. It retains neither the YAML tree/source text
// nor overwritten origins, and is discarded with its owning engine session.
type Provenance struct {
	definitions map[string]map[string]*DefinitionProvenance
	rules       map[string][]*DefinitionProvenance
}

// Definition returns a configured node, group or provider definition. Missing,
// built-in and default objects return nil; downloaded provider content has separate
// provenance.
func (p *Provenance) Definition(section, name string) *DefinitionProvenance {
	if p == nil {
		return nil
	}
	return p.definitions[section][name]
}

// Rule indexes the final composed rule list, before search/pagination. The main
// scope is empty; other scopes are sub-rule names. The fixed parser retains one
// compiled rule per valid input item, including duplicate declarations.
func (p *Provenance) Rule(scope string, index int) *DefinitionProvenance {
	if p == nil || index < 0 || index >= len(p.rules[scope]) {
		return nil
	}
	return p.rules[scope][index]
}

// nodeOrigins tracks the actual merge nodes. Scalars and empty containers carry value
// origins; nonempty containers contribute their surviving children.
type nodeOrigins map[*yaml.Node]fieldOrigin

func provenancePath(parent, key string) string {
	return parent + "/" + strings.ReplaceAll(strings.ReplaceAll(key, "~", "~0"), "/", "~1")
}

func (origins nodeOrigins) capture(node *yaml.Node, source SourceOrigin, path string) {
	origins[node] = fieldOrigin{SourceOrigin: source, Path: path}
	switch node.Kind {
	case yaml.MappingNode:
		for i := 0; i < len(node.Content); i += 2 {
			key := node.Content[i].Value
			if path == "" {
				switch key {
				case "proxies", "proxy-groups", "proxy-providers", "rule-providers", "rules", "sub-rules":
				default:
					continue // No unused full-configuration attribution database.
				}
			}
			origins.capture(node.Content[i+1], source, provenancePath(path, key))
		}
	case yaml.SequenceNode:
		for index, item := range node.Content {
			origins.capture(item, source, provenancePath(path, strconv.Itoa(index)))
		}
	}
}

func (origins nodeOrigins) inherit(result, source *yaml.Node) {
	if origin, exists := origins[source]; exists {
		origins[result] = origin
	}
}

func sourceDefinitionPath(path string) string {
	parts := strings.Split(path, "/")
	count := 3 // /proxies/index, /proxy-groups/index, /provider-section/name, /rules/index
	if len(parts) > 1 && parts[1] == "sub-rules" {
		count = 4 // /sub-rules/scope/index
	}
	if len(parts) > count {
		parts = parts[:count]
	}
	return strings.Join(parts, "/")
}

func (origins nodeOrigins) definition(node *yaml.Node, priority map[SourceOrigin]int) *DefinitionProvenance {
	result := &DefinitionProvenance{}
	contributions := make(map[SourceOrigin]string)
	complete := true
	var visit func(*yaml.Node)
	visit = func(node *yaml.Node) {
		if node.Kind == yaml.MappingNode && len(node.Content) > 0 {
			for i := 1; i < len(node.Content); i += 2 {
				visit(node.Content[i])
			}
			return
		}
		if node.Kind == yaml.SequenceNode && len(node.Content) > 0 {
			for _, item := range node.Content {
				visit(item)
			}
			return
		}
		origin, exists := origins[node]
		if !exists {
			complete = false
			return
		}
		contributions[origin.SourceOrigin] = sourceDefinitionPath(origin.Path)
	}
	visit(node)
	if !complete {
		return nil
	}
	for source, path := range contributions {
		result.Contributors = append(result.Contributors, SourceContribution{SourceOrigin: source, Path: path})
	}
	sort.Slice(result.Contributors, func(i, j int) bool {
		return priority[result.Contributors[i].SourceOrigin] < priority[result.Contributors[j].SourceOrigin]
	})
	return result
}

func (origins nodeOrigins) project(root *yaml.Node, priority map[SourceOrigin]int) *Provenance {
	result := &Provenance{
		definitions: make(map[string]map[string]*DefinitionProvenance),
		rules:       make(map[string][]*DefinitionProvenance),
	}
	putRules := func(scope string, list *yaml.Node) {
		if list.Kind != yaml.SequenceNode {
			return // Public config parsing still owns value/type validity.
		}
		for _, rule := range list.Content {
			result.rules[scope] = append(result.rules[scope], origins.definition(rule, priority))
		}
	}
	for i := 0; i < len(root.Content); i += 2 {
		section, value := root.Content[i].Value, root.Content[i+1]
		switch section {
		case "proxies", "proxy-groups":
			if value.Kind != yaml.SequenceNode {
				continue
			}
			definitions := make(map[string]*DefinitionProvenance)
			for _, item := range value.Content {
				if name, ok := namedConfigName(item); ok {
					definitions[name] = origins.definition(item, priority)
				}
			}
			result.definitions[section] = definitions
		case "proxy-providers", "rule-providers":
			if value.Kind != yaml.MappingNode {
				continue
			}
			definitions := make(map[string]*DefinitionProvenance)
			for j := 0; j < len(value.Content); j += 2 {
				definitions[value.Content[j].Value] = origins.definition(value.Content[j+1], priority)
			}
			result.definitions[section] = definitions
		case "rules":
			putRules("", value)
		case "sub-rules":
			if value.Kind == yaml.MappingNode {
				for j := 0; j < len(value.Content); j += 2 {
					putRules(value.Content[j].Value, value.Content[j+1])
				}
			}
		}
	}
	return result
}
