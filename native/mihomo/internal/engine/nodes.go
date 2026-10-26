package engine

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"
	"strings"

	G "github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"

	"clashpseudo/native/internal/configinput"
)

var errNodesChanged = errors.New("proxy provider membership changed")

type NodeQuery struct {
	Offset int     `json:"offset"`
	Limit  int     `json:"limit"`
	Search string  `json:"search"`
	Token  string  `json:"token"`
	Source *string `json:"source,omitempty"`
}

type Node struct {
	Name          string            `json:"name"`
	Type          string            `json:"type"`
	Source        string            `json:"source"`
	SourceKind    string            `json:"sourceKind"`
	SourceVersion uint32            `json:"sourceVersion"`
	Builtin       bool              `json:"builtin"`
	UDP           bool              `json:"udp"`
	UOT           bool              `json:"uot"`
	XUDP          bool              `json:"xudp"`
	TFO           bool              `json:"tfo"`
	MPTCP         bool              `json:"mptcp"`
	SMUX          bool              `json:"smux"`
	History       []C.DelayHistory  `json:"history"`
	Tests         []NodeTestHistory `json:"tests"`
	// Downloaded provider members retain their provider-content provenance.
	Provenance         *configinput.DefinitionProvenance `json:"provenance,omitempty"`
	ProviderProvenance *configinput.DefinitionProvenance `json:"providerProvenance,omitempty"`
}

type NodeTestHistory struct {
	Target  string           `json:"target"`
	Alive   bool             `json:"alive"`
	History []C.DelayHistory `json:"history"`
}

type NodePage struct {
	Nodes      []Node `json:"nodes"`
	Total      int    `json:"total"`
	NextOffset int    `json:"nextOffset"`
	Token      string `json:"token"`
}

func (e *Engine) Nodes(query NodeQuery) (string, error) {
	if query.Offset < 0 || query.Limit < 1 || query.Limit > 100 || len(query.Search) > 4096 ||
		(query.Source != nil && len(*query.Source) > 4096) ||
		(query.Offset > 0 && len(query.Token) != 64) {
		return "", errors.New("invalid node query")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return "", ErrStopped
	}

	// Check provider version before and after membership projection; expire pages across
	// revisions.
	type source struct {
		name     string
		provider P.ProxyProvider
		version  uint32
		proxies  []C.Proxy
	}
	names := make([]string, 0, len(e.cfg.Providers))
	for name, provider := range e.cfg.Providers {
		// Compatible providers represent synthetic group references to top-level nodes.
		if provider.VehicleType() != P.Compatible && (query.Source == nil || name == *query.Source) {
			names = append(names, name)
		}
	}
	if query.Source != nil && len(names) == 0 {
		return "", errors.New("proxy provider source is unavailable")
	}
	declaredSourceOrder(names, e.sources.proxyProviders)
	sources := make([]source, 0, len(names))
	type stamp struct {
		Name    string
		Version uint32
	}
	stamps := make([]stamp, 0, len(names))
	for _, name := range names {
		provider := e.cfg.Providers[name]
		version := provider.Version()
		sources = append(sources, source{name, provider, version, provider.Proxies()})
		stamps = append(stamps, stamp{name, version})
	}
	identity, err := json.Marshal(struct {
		Search  string
		Source  *string
		Sources []stamp
	}{query.Search, query.Source, stamps})
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256(identity)
	token := hex.EncodeToString(hash[:])
	if query.Token != "" && query.Token != token {
		return "", errNodesChanged
	}
	page := NodePage{Nodes: make([]Node, 0, query.Limit), NextOffset: -1, Token: token}
	search := strings.ToLower(strings.TrimSpace(query.Search))
	appendNode := func(proxy C.Proxy, source string, fromProvider bool, version uint32) {
		if _, group := proxy.Adapter().(G.ProxyGroup); group {
			return
		}
		if !strings.Contains(strings.ToLower(proxy.Name()), search) &&
			!strings.Contains(strings.ToLower(proxy.Type().String()), search) &&
			!strings.Contains(strings.ToLower(source), search) {
			return
		}
		index := page.Total
		page.Total++
		if index < query.Offset || len(page.Nodes) >= query.Limit {
			return
		}
		info := proxy.ProxyInfo()
		node := Node{Name: proxy.Name(), Type: proxy.Type().String(), Source: source, SourceVersion: version,
			UDP: proxy.SupportUDP(), UOT: proxy.SupportUOT(), XUDP: info.XUDP,
			TFO: info.TFO, MPTCP: info.MPTCP, SMUX: info.SMUX,
			History: proxy.DelayHistory(), Tests: make([]NodeTestHistory, 0)}
		if fromProvider {
			node.SourceKind = "proxyProvider"
			node.ProviderProvenance = e.provenance.Definition("proxy-providers", source)
		} else {
			node.SourceKind = "configuration"
			node.Provenance = e.provenance.Definition("proxies", node.Name)
			switch node.Name {
			case "DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS", "PASS-RULE":
				node.Builtin = true
			}
		}
		extra := proxy.ExtraDelayHistories()
		urls := make([]string, 0, len(extra))
		for url := range extra {
			urls = append(urls, url)
		}
		sort.Strings(urls)
		for _, url := range urls {
			state := extra[url]
			node.Tests = append(node.Tests, NodeTestHistory{redactPresent(url), state.Alive, state.History})
		}
		page.Nodes = append(page.Nodes, node)
	}
	if query.Source == nil {
		top := make([]string, 0, len(e.cfg.Proxies))
		for name := range e.cfg.Proxies {
			top = append(top, name)
		}
		declaredSourceOrder(top, e.sources.proxies)
		for _, name := range top {
			appendNode(e.cfg.Proxies[name], "", false, 0)
		}
	}
	for _, source := range sources {
		for _, proxy := range source.proxies {
			appendNode(proxy, source.name, true, source.version)
		}
	}
	for _, source := range sources {
		if source.provider.Version() != source.version {
			return "", errNodesChanged
		}
	}
	if query.Offset > page.Total {
		return "", errors.New("node page is out of range")
	}
	if query.Offset+len(page.Nodes) < page.Total {
		page.NextOffset = query.Offset + len(page.Nodes)
	}
	data, err := json.Marshal(page)
	if err != nil {
		return "", err
	}
	if len(data) > 8<<20 {
		return "", errors.New("node page exceeds response budget")
	}
	return string(data), nil
}
