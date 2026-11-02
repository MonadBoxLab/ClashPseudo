package coreview

import (
	"container/heap"
	"encoding/json"
	"errors"
	"fmt"
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
	if len(body) > MaxConnectionRequest {
		return q, errConnections
	}
	if err := json.Unmarshal(body, &q); err != nil {
		return q, errors.Join(errConnections, err)
	}
	return q, q.Validate()
}

func ValidConnectionID(id string) bool {
	if len(id) != 36 {
		return false
	}
	value, err := uuid.FromString(id)
	return err == nil && value.String() == id && value != uuid.Nil
}

func (q ConnectionQuery) Validate() error {
	if q.Limit < 1 || q.Limit > MaxConnectionRows || len(q.PreviousActiveIDs) > MaxConnectionRows {
		return errConnections
	}
	seen := make(map[string]bool, len(q.PreviousActiveIDs))
	for _, id := range q.PreviousActiveIDs {
		if !ValidConnectionID(id) || seen[id] {
			return errConnections
		}
		seen[id] = true
	}
	if q.DetailID != "" && !ValidConnectionID(q.DetailID) {
		return errConnections
	}
	return nil
}

type ConnectionSource interface {
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
	Omitted         int               `json:"omitted"`
}

// ConnectionTotals is an observation captured by the session. Session values
// have already been calculated from that session's traffic baseline.
type ConnectionTotals struct {
	Upload, Download               int64
	SessionUpload, SessionDownload *int64
}

func Connections(source ConnectionSource, proxies map[string]C.Proxy, q ConnectionQuery, totals ConnectionTotals) (string, error) {
	if err := q.Validate(); err != nil {
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
		id := tracker.ID()
		if !ValidConnectionID(id) {
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
		}
		checked[id] = info
		return info
	}
	response := connectionReply{
		Connections: make([]json.RawMessage, 0, len(candidates)),
		Presence:    make(map[string]bool, len(q.PreviousActiveIDs)+1),
		Limited:     count > q.Limit, Complete: true,
	}
	for _, id := range q.PreviousActiveIDs {
		response.Presence[id] = lookup(id) != nil
	}
	if q.DetailID != "" {
		response.Presence[q.DetailID] = lookup(q.DetailID) != nil
	}
	response.UploadTotal, response.DownloadTotal = totals.Upload, totals.Download
	response.SessionUpload, response.SessionDownload = totals.SessionUpload, totals.SessionDownload
	response.ActiveCount, response.Omitted = count, count
	header, err := json.Marshal(response)
	if err != nil {
		return "", err
	}
	rowBudget := maxConnectionResponse - len(header)
	selected := make(map[string]bool, len(candidates))
	rowBytes := 0
	for _, candidate := range candidates {
		if info := lookup(candidate.id); info != nil {
			row, err := projectConnection(proxies, candidate.id, info)
			if err != nil {
				return "", err
			}
			if rowBytes+len(row)+len(response.Connections) > rowBudget {
				response.Limited = true
				continue
			}
			rowBytes += len(row)
			response.Connections = append(response.Connections, row)
			selected[candidate.id] = true
		}
	}
	if q.DetailID != "" {
		info := lookup(q.DetailID)
		response.Presence[q.DetailID] = info != nil
		if info != nil && !selected[q.DetailID] {
			row, err := projectConnection(proxies, q.DetailID, info)
			if err != nil {
				return "", err
			}
			if len(row)+len(`,"detail":`) > rowBudget {
				response.Limited = true
			} else {
				response.Detail = row
			}
		}
	}
	if scanError != nil {
		return "", scanError
	}
	response.Omitted = max(0, count-len(response.Connections))
	if response.Detail != nil {
		response.Omitted = max(0, response.Omitted-1)
	}
	rowBytes += len(response.Detail)
	for {
		envelope := response
		envelope.Connections = []json.RawMessage{}
		envelope.Detail = nil
		header, err := json.Marshal(envelope)
		if err != nil {
			return "", err
		}
		size := len(header) + rowBytes + max(0, len(response.Connections)-1)
		if response.Detail != nil {
			size += len(`,"detail":`)
		}
		if size <= maxConnectionResponse {
			body, err := json.Marshal(response)
			return string(body), err
		}
		response.Limited = true
		response.Omitted++
		if last := len(response.Connections) - 1; last >= 0 {
			rowBytes -= len(response.Connections[last])
			response.Connections[last] = nil
			response.Connections = response.Connections[:last]
		} else if response.Detail != nil {
			rowBytes -= len(response.Detail)
			response.Detail = nil
		} else {
			return "", fmt.Errorf("connection response: %d bytes exceeds %d", size, maxConnectionResponse)
		}
	}
}

type connectionStrategy struct {
	Type string `json:"type"`
	Icon string `json:"icon"`
}

func projectConnection(proxies map[string]C.Proxy, id string, info *statistic.TrackerInfo) (json.RawMessage, error) {
	var descriptor *connectionStrategy
	for i := len(info.Chain) - 1; i >= 0; i-- {
		proxy := proxies[info.Chain[i]]
		if proxy == nil {
			continue
		}
		if group, ok := proxy.Adapter().(G.ProxyGroup); ok {
			descriptor = &connectionStrategy{Type: StrategyType(group.Type()), Icon: group.Icon()}
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
	return json.Marshal(struct {
		*statistic.TrackerInfo
		Strategy        *connectionStrategy        `json:"strategy,omitempty"`
		RuleSuggestions *connectionRuleSuggestions `json:"ruleSuggestions,omitempty"`
	}{info, descriptor, connectionSuggestions(id, info.Metadata)})
}
