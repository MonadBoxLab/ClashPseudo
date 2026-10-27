package engine

import (
	"container/heap"
	"encoding/json"
	"errors"
	"net/netip"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"clashpseudo/native/internal/appcontract"

	"github.com/gofrs/uuid/v5"
	G "github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"golang.org/x/net/idna"
	"golang.org/x/net/publicsuffix"
)

const (
	MaxConnectionRows     = appcontract.ConnectionActiveEntries
	MaxConnectionRequest  = appcontract.ConnectionRequestBytes
	maxConnectionRowBytes = appcontract.ConnectionRowBytes
	maxConnectionResponse = appcontract.ConnectionResponseBytes
)

var errConnections = errors.New("connection query failed")

type ConnectionQuery struct {
	Limit             int      `json:"limit"`
	PreviousActiveIDs []string `json:"previousActiveIds"`
	DetailID          string   `json:"detailId"`
}

func DecodeConnectionQuery(body []byte) (ConnectionQuery, error) {
	var q ConnectionQuery
	if len(body) > MaxConnectionRequest || json.Unmarshal(body, &q) != nil {
		return q, errConnections
	}
	return q, q.validate()
}

func validConnectionID(id string) bool {
	if len(id) != 36 {
		return false
	}
	value, err := uuid.FromString(id)
	return err == nil && value.String() == id && value != uuid.Nil
}

func (q ConnectionQuery) validate() error {
	if q.Limit < 1 || q.Limit > MaxConnectionRows || len(q.PreviousActiveIDs) > MaxConnectionRows {
		return errConnections
	}
	seen := make(map[string]bool, len(q.PreviousActiveIDs))
	for _, id := range q.PreviousActiveIDs {
		if !validConnectionID(id) || seen[id] {
			return errConnections
		}
		seen[id] = true
	}
	if q.DetailID != "" && !validConnectionID(q.DetailID) {
		return errConnections
	}
	return nil
}

type connectionSource interface {
	Total() (int64, int64)
	Range(func(statistic.Tracker) bool)
	Get(string) statistic.Tracker
}

type connectionCandidate struct {
	id    string
	start time.Time
}

type connectionHeap []connectionCandidate

func (h connectionHeap) Len() int { return len(h) }
func (h connectionHeap) Less(i, j int) bool {
	if h[i].start.Equal(h[j].start) {
		return h[i].id > h[j].id
	}
	return h[i].start.Before(h[j].start)
}
func (h connectionHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }
func (h *connectionHeap) Push(v any)   { *h = append(*h, v.(connectionCandidate)) }
func (h *connectionHeap) Pop() any {
	old := *h
	last := old[len(old)-1]
	*h = old[:len(old)-1]
	return last
}

type connectionRuleSuggestions struct {
	ConnectionID   string  `json:"connectionId"`
	Host           *string `json:"host"`
	SuffixBoundary *string `json:"suffixBoundary"`
	IPCIDR         *string `json:"ipCidr"`
}

// Build PSL scope suggestions from the complete current tracker metadata.
func connectionSuggestions(id string, metadata *C.Metadata) *connectionRuleSuggestions {
	value := &connectionRuleSuggestions{ConnectionID: id}
	if metadata == nil {
		return value
	}
	observed := *metadata
	if ip := observed.DstIP.Unmap(); ip.IsValid() && !ip.IsUnspecified() && ip.Zone() == "" && !resolver.IsFakeIP(ip) {
		cidr := netip.PrefixFrom(ip, ip.BitLen()).String()
		value.IPCIDR = &cidr
	}
	host := observed.Host
	if host == "" || len(host) > 1024 || !utf8.ValidString(host) || strings.ContainsAny(host, ":/\\@?#%[]") {
		return value
	}
	host, err := idna.Lookup.ToASCII(host)
	if err != nil {
		return value
	}
	host = strings.TrimSuffix(strings.ToLower(host), ".")
	if len(host) == 0 || len(host) > 253 {
		return value
	}
	if _, err := netip.ParseAddr(host); err == nil {
		return value
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return value
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return value
			}
		}
	}
	value.Host = &host
	registrable, err := publicsuffix.EffectiveTLDPlusOne(host)
	if err == nil {
		value.SuffixBoundary = &registrable
	}
	return value
}

type connectionReply struct {
	UploadTotal     int64             `json:"uploadTotal"`
	DownloadTotal   int64             `json:"downloadTotal"`
	SessionUpload   *int64            `json:"sessionUploadBytes"`
	SessionDownload *int64            `json:"sessionDownloadBytes"`
	ActiveCount     int               `json:"activeCount"`
	Connections     []json.RawMessage `json:"connections"`
	Detail          json.RawMessage   `json:"detail,omitempty"`
	Presence        map[string]bool   `json:"presence"`
	Limited         bool              `json:"limited"`
	Complete        bool              `json:"complete"`
}

func (e *Engine) Connections(q ConnectionQuery) (string, error) {
	if err := q.validate(); err != nil {
		return "", err
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() || e.tun == nil {
		return "", ErrStopped
	}
	return queryConnections(statistic.DefaultManager, e.cfg.Proxies, q, e.traffic)
}

func queryConnections(source connectionSource, proxies map[string]C.Proxy, q ConnectionQuery, baseline ...*trafficBaseline) (string, error) {
	if err := q.validate(); err != nil {
		return "", err
	}
	candidates := make(connectionHeap, 0, q.Limit)
	count := 0
	var scanError error
	source.Range(func(tracker statistic.Tracker) bool {
		info := tracker.Info()
		if info == nil {
			scanError = errConnections
			return false
		}
		if info.Metadata != nil && info.Metadata.Type == C.INNER {
			return true
		}
		id := tracker.ID()
		if !validConnectionID(id) {
			scanError = errConnections
			return false
		}
		count++
		candidate := connectionCandidate{id: id, start: info.Start}
		if len(candidates) < q.Limit {
			heap.Push(&candidates, candidate)
		} else if candidate.start.After(candidates[0].start) ||
			(candidate.start.Equal(candidates[0].start) && candidate.id < candidates[0].id) {
			candidates[0] = candidate
			heap.Fix(&candidates, 0)
		}
		return true
	})
	if scanError != nil {
		return "", scanError
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].start.Equal(candidates[j].start) {
			return candidates[i].id < candidates[j].id
		}
		return candidates[i].start.After(candidates[j].start)
	})

	// Reuse each Get observation within this response.
	checked := make(map[string]*statistic.TrackerInfo, q.Limit+len(q.PreviousActiveIDs)+1)
	lookup := func(id string) *statistic.TrackerInfo {
		if info, ok := checked[id]; ok {
			return info
		}
		var info *statistic.TrackerInfo
		if tracker := source.Get(id); tracker != nil {
			info = tracker.Info()
			if info == nil {
				scanError = errConnections
			}
			if info != nil && info.Metadata != nil && info.Metadata.Type == C.INNER {
				info = nil
			}
		}
		checked[id] = info
		return info
	}
	response := connectionReply{
		Connections: make([]json.RawMessage, 0, len(candidates)),
		Presence:    make(map[string]bool, len(q.PreviousActiveIDs)+1),
		Limited:     count > q.Limit, Complete: true,
	}
	selected := make(map[string]bool, len(candidates))
	for _, candidate := range candidates {
		if info := lookup(candidate.id); info != nil {
			row, err := projectConnection(proxies, candidate.id, info)
			if err != nil {
				return "", err
			}
			response.Connections = append(response.Connections, row)
			selected[candidate.id] = true
		}
	}
	for _, id := range q.PreviousActiveIDs {
		response.Presence[id] = lookup(id) != nil
	}
	if q.DetailID != "" {
		info := lookup(q.DetailID)
		response.Presence[q.DetailID] = info != nil
		if info != nil && !selected[q.DetailID] {
			row, err := projectConnection(proxies, q.DetailID, info)
			if err != nil {
				return "", err
			}
			response.Detail = row
		}
	}
	if scanError != nil {
		return "", scanError
	}
	response.UploadTotal, response.DownloadTotal = source.Total()
	if len(baseline) > 0 {
		response.SessionUpload, response.SessionDownload = baseline[0].totals(response.UploadTotal, response.DownloadTotal)
	}
	response.ActiveCount = count
	body, err := json.Marshal(response)
	if err != nil || len(body) > maxConnectionResponse {
		return "", errConnections
	}
	return string(body), nil
}

type connectionMetadata struct {
	Host            string `json:"host,omitempty"`
	DestinationIP   string `json:"destinationIP,omitempty"`
	DestinationPort uint16 `json:"destinationPort,string"`
	SourceIP        string `json:"sourceIP,omitempty"`
	SourcePort      uint16 `json:"sourcePort,string"`
	Network         string `json:"network"`
	Type            string `json:"type"`
}

type connectionStrategy struct {
	Type string `json:"type"`
	Icon string `json:"icon"`
}

type connectionRow struct {
	RuleSuggestions *connectionRuleSuggestions `json:"ruleSuggestions,omitempty"`
	Strategy        *connectionStrategy        `json:"strategy,omitempty"`
	ID              string                     `json:"id"`
	Start           time.Time                  `json:"start"`
	Upload          int64                      `json:"upload"`
	Download        int64                      `json:"download"`
	Chains          []string                   `json:"chains"`
	Rule            string                     `json:"rule"`
	RulePayload     string                     `json:"rulePayload"`
	Metadata        *connectionMetadata        `json:"metadata,omitempty"`
	Truncated       bool                       `json:"fieldsTruncated,omitempty"`
}

// Copy bounded strings before encoding to release larger source backing storage.
func connectionText(value string, limit int, truncated *bool) string {
	if len(value) > limit {
		*truncated = true
		for limit > 0 && !utf8.RuneStart(value[limit]) {
			limit--
		}
		value = value[:limit]
	}
	if !utf8.ValidString(value) {
		*truncated = true
		value = strings.ToValidUTF8(value, "�")
	}
	return strings.Clone(value)
}

func projectConnection(proxies map[string]C.Proxy, id string, info *statistic.TrackerInfo) (json.RawMessage, error) {
	var descriptor *connectionStrategy
	iconOmitted := false
	// Resolve the entry group from the full, exact chain before display truncation.
	for i := len(info.Chain) - 1; i >= 0; i-- {
		proxy := proxies[info.Chain[i]]
		if proxy == nil {
			continue
		}
		if group, ok := proxy.Adapter().(G.ProxyGroup); ok {
			icon := group.Icon()
			if len(icon) > 1024 || !utf8.ValidString(icon) {
				icon, iconOmitted = "", true
			} else if encoded, _ := json.Marshal(icon); len(encoded) > 1024 {
				icon, iconOmitted = "", true
			}
			descriptor = &connectionStrategy{Type: strategyType(group.Type()), Icon: strings.Clone(icon)}
			break
		}
	}
	if descriptor == nil && len(info.Chain) > 0 {
		switch info.Chain[0] {
		case "DIRECT":
			descriptor = &connectionStrategy{Type: "Direct"}
		case "REJECT", "REJECT-DROP":
			descriptor = &connectionStrategy{Type: "Reject"}
		}
	}
	suggestions := connectionSuggestions(id, info.Metadata)
	for scale := 1; scale <= 16; scale *= 2 {
		row := connectionRow{ID: id, Start: info.Start, Strategy: descriptor, RuleSuggestions: suggestions,
			Upload: info.UploadTotal.Load(), Download: info.DownloadTotal.Load(),
			Chains: make([]string, 0, min(len(info.Chain), 16)), Truncated: len(info.Chain) > 16 || iconOmitted}
		text := func(s string, n int) string { return connectionText(s, n/scale, &row.Truncated) }
		row.Rule = text(info.Rule, 64)
		row.RulePayload = text(info.RulePayload, 512)
		for _, chain := range info.Chain[:min(len(info.Chain), 16)] {
			row.Chains = append(row.Chains, text(chain, 128))
		}
		if meta := info.Metadata; meta != nil {
			row.Metadata = &connectionMetadata{Host: text(meta.Host, 512),
				SourcePort: meta.SrcPort, DestinationPort: meta.DstPort,
				Network: meta.NetWork.String(), Type: meta.Type.String()}
			if meta.SrcIP.IsValid() {
				row.Metadata.SourceIP = meta.SrcIP.String()
			}
			if meta.DstIP.IsValid() {
				row.Metadata.DestinationIP = meta.DstIP.String()
			}
		}
		body, err := json.Marshal(row)
		if err != nil {
			return nil, errConnections
		}
		if len(body) <= maxConnectionRowBytes {
			return body, nil
		}
	}
	return nil, errConnections
}

func (e *Engine) CloseConnection(id string) (string, error) {
	if !validConnectionID(id) {
		return "", errors.New("invalid connection ID")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() || e.tun == nil {
		return "", ErrStopped
	}
	return closeConnection(statistic.DefaultManager, id)
}

func closeConnection(source connectionSource, id string) (string, error) {
	tracker := source.Get(id)
	if tracker == nil {
		return "absent", nil
	}
	info := tracker.Info()
	if info == nil || (info.Metadata != nil && info.Metadata.Type == C.INNER) {
		return "", errors.New("connection cannot be closed")
	}
	if err := tracker.Close(); err != nil {
		// Tracker.Close may remove the record before the underlying Close fails.
		return "", errors.New("connection close failed")
	}
	return "closed", nil
}
