package engine

import (
	"container/heap"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gofrs/uuid/v5"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const (
	MaxConnectionRows     = 1000
	MaxConnectionRequest  = 64 << 10
	maxConnectionRowBytes = 4 << 10
	maxConnectionResponse = 8 << 20
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

type connectionReply struct {
	Connections []json.RawMessage `json:"connections"`
	Detail      json.RawMessage   `json:"detail,omitempty"`
	Presence    map[string]bool   `json:"presence"`
	Limited     bool              `json:"limited"`
	Complete    bool              `json:"complete"`
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
	return queryConnections(statistic.DefaultManager, q)
}

func queryConnections(source connectionSource, q ConnectionQuery) (string, error) {
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

	// Reuse each Get result inside this response. Range/Get are not a transaction.
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
			row, err := projectConnection(candidate.id, info)
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
			row, err := projectConnection(q.DetailID, info)
			if err != nil {
				return "", err
			}
			response.Detail = row
		}
	}
	if scanError != nil {
		return "", scanError
	}
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

type connectionRow struct {
	ID          string              `json:"id"`
	Start       time.Time           `json:"start"`
	Upload      int64               `json:"upload"`
	Download    int64               `json:"download"`
	Chains      []string            `json:"chains"`
	Rule        string              `json:"rule"`
	RulePayload string              `json:"rulePayload"`
	Metadata    *connectionMetadata `json:"metadata,omitempty"`
	Truncated   bool                `json:"fieldsTruncated,omitempty"`
}

// Copy bounded text before encoding; a small substring must not retain a huge source string.
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

func projectConnection(id string, info *statistic.TrackerInfo) (json.RawMessage, error) {
	for scale := 1; scale <= 16; scale *= 2 {
		row := connectionRow{ID: id, Start: info.Start,
			Upload: info.UploadTotal.Load(), Download: info.DownloadTotal.Load(),
			Chains: make([]string, 0, min(len(info.Chain), 16)), Truncated: len(info.Chain) > 16}
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
