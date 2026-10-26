package engine

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

func TestNodesIncludeProviderMembersAndExcludeGroups(t *testing.T) {
	var e Engine
	body := []byte(`proxies:
 - {name: shared-name, type: direct}
proxy-providers:
 first:
  type: inline
  payload:
   - {name: shared-name, type: socks5, server: 127.0.0.1, port: 9, username: secret-user, password: secret-password}
 second:
  type: inline
  payload:
   - {name: shared-name, type: direct}
proxy-groups:
 - name: Group
   type: select
   proxies: [DIRECT, shared-name]
   use: [first, second]
rules:
 - MATCH,DIRECT
`)
	if err := e.Prepare(t.TempDir(), body, "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	query := NodeQuery{Limit: 1, Search: "shared-name"}
	var sources []string
	for {
		value, err := e.Nodes(query)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(value, "secret-") || strings.Contains(value, "127.0.0.1") {
			t.Fatal("node query exposed credentials or endpoint")
		}
		var page NodePage
		if err := json.Unmarshal([]byte(value), &page); err != nil {
			t.Fatal(err)
		}
		if page.Total != 3 || len(page.Nodes) != 1 {
			t.Fatalf("unexpected page: %+v", page)
		}
		node := page.Nodes[0]
		if node.Builtin {
			t.Fatal("custom node marked as builtin")
		}
		kind := "proxyProvider"
		if node.Source == "" {
			kind = "configuration"
		}
		if node.SourceKind != kind {
			t.Fatalf("node source identity = %q, want %q", node.SourceKind, kind)
		}
		if !strings.Contains(value, `"sourceVersion":`) {
			t.Fatal("node response omitted its source version")
		}
		var version uint32
		if kind == "proxyProvider" {
			version = e.cfg.Providers[node.Source].Version()
		}
		if node.SourceVersion != version {
			t.Fatalf("node source version = %d, want %d", node.SourceVersion, version)
		}
		sources = append(sources, node.Source)
		if page.NextOffset == -1 {
			break
		}
		query.Offset, query.Token = page.NextOffset, page.Token
	}
	if strings.Join(sources, ",") != ",first,second" {
		t.Fatal(sources)
	}
	value, err := e.Nodes(NodeQuery{Limit: 100})
	if err != nil {
		t.Fatal(err)
	}
	var page NodePage
	if err := json.Unmarshal([]byte(value), &page); err != nil {
		t.Fatal(err)
	}
	builtins := 0
	for _, node := range page.Nodes {
		if node.Name == "Group" || node.Name == "GLOBAL" {
			t.Fatal("group appeared as node")
		}
		if node.Builtin {
			builtins++
		}
	}
	if builtins != 6 {
		t.Fatalf("builtin count: %d", builtins)
	}
}

func TestNodesExactProviderFilterKeepsSearchAndPagination(t *testing.T) {
	var e Engine
	body := []byte(`proxies:
 - {name: shared-name, type: direct}
proxy-providers:
 '':
  type: inline
  payload:
   - {name: DIRECT, type: direct}
 alpha-extra:
  type: inline
  payload:
   - {name: shared-name, type: direct}
 alpha:
  type: inline
  payload:
   - {name: shared-name, type: direct}
   - {name: alpha-second, type: direct}
rules:
 - MATCH,DIRECT
`)
	if err := e.Prepare(t.TempDir(), body, "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	read := func(source, search, token string, offset int) (NodePage, error) {
		request, err := json.Marshal(map[string]any{"source": source, "search": search, "token": token, "offset": offset, "limit": 1})
		if err != nil {
			t.Fatal(err)
		}
		var query NodeQuery
		if err := json.Unmarshal(request, &query); err != nil {
			t.Fatal(err)
		}
		value, err := e.Nodes(query)
		var page NodePage
		if err == nil {
			err = json.Unmarshal([]byte(value), &page)
		}
		return page, err
	}
	first, err := read("alpha", "", "", 0)
	if err != nil || first.Total != 2 || first.NextOffset != 1 || len(first.Nodes) != 1 || first.Nodes[0].Source != "alpha" || first.Nodes[0].Name != "shared-name" {
		t.Fatalf("exact source first page = %+v, %v", first, err)
	}
	// A different provider can change while this exact-source dataset stays valid.
	unrelated := &nodeChangingProvider{version: 1, changeOnRead: true}
	e.cfg.Providers["unrelated"] = unrelated
	defer delete(e.cfg.Providers, "unrelated")
	next, err := read("alpha", "", first.Token, first.NextOffset)
	if err != nil || next.Total != 2 || next.NextOffset != -1 || len(next.Nodes) != 1 || next.Nodes[0].Source != "alpha" || next.Nodes[0].Name != "alpha-second" {
		t.Fatalf("exact source next page = %+v, %v", next, err)
	}
	unrelated.changeOnRead = false
	filtered, err := read("alpha", "shared", "", 0)
	if err != nil || filtered.Total != 1 || len(filtered.Nodes) != 1 || filtered.Nodes[0].Source != "alpha" {
		t.Fatalf("search within exact source = %+v, %v", filtered, err)
	}
	emptyName, err := read("", "", "", 0)
	if err != nil || emptyName.Total != 1 || len(emptyName.Nodes) != 1 || emptyName.Nodes[0].Name != "DIRECT" || emptyName.Nodes[0].Builtin || emptyName.Nodes[0].SourceKind != "proxyProvider" {
		t.Fatalf("explicit empty provider name = %+v, %v", emptyName, err)
	}
	if _, err := e.Nodes(NodeQuery{Limit: 100}); err != nil {
		t.Fatalf("omitted source global query: %v", err)
	}
	if _, err := read("alpha-extra", "", first.Token, 0); !errors.Is(err, errNodesChanged) {
		t.Fatalf("token reused for another source: %v", err)
	}
	if _, err := read("missing", "", "", 0); err == nil {
		t.Fatal("unavailable provider source accepted")
	}
	if _, err := read(strings.Repeat("x", 4097), "", "", 0); err == nil {
		t.Fatal("overlong provider source accepted")
	}
}

type nodeChangingProvider struct {
	P.ProxyProvider
	version      uint32
	changeOnRead bool
}

func (p *nodeChangingProvider) VehicleType() P.VehicleType { return P.Inline }
func (p *nodeChangingProvider) Version() uint32            { return p.version }
func (p *nodeChangingProvider) Proxies() []C.Proxy {
	if p.changeOnRead {
		p.version++
	}
	return nil
}

func TestNodePagesRejectProviderUpdatesAndInvalidRequests(t *testing.T) {
	var e Engine
	if _, err := e.Nodes(NodeQuery{Limit: 10}); !errors.Is(err, ErrStopped) {
		t.Fatal(err)
	}
	if err := e.Prepare(t.TempDir(), []byte("rules:\n - MATCH,DIRECT\n"), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	provider := &nodeChangingProvider{version: 1}
	e.cfg.Providers["changing"] = provider
	defer delete(e.cfg.Providers, "changing")
	value, err := e.Nodes(NodeQuery{Limit: 1})
	if err != nil {
		t.Fatal(err)
	}
	var page NodePage
	if err := json.Unmarshal([]byte(value), &page); err != nil {
		t.Fatal(err)
	}
	provider.version++
	if _, err := e.Nodes(NodeQuery{Limit: 1, Offset: 1, Token: page.Token}); !errors.Is(err, errNodesChanged) {
		t.Fatal(err)
	}
	provider.changeOnRead = true
	if _, err := e.Nodes(NodeQuery{Limit: 1}); !errors.Is(err, errNodesChanged) {
		t.Fatal(err)
	}
	provider.changeOnRead = false
	for _, query := range []NodeQuery{{}, {Limit: 101}, {Limit: 1, Offset: -1}, {Limit: 1, Offset: 1}, {Limit: 1, Search: strings.Repeat("x", 4097)}} {
		if _, err := e.Nodes(query); err == nil {
			t.Fatal("invalid query accepted")
		}
	}
}
