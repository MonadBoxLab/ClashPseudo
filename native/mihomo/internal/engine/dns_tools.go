package engine

import (
	"context"
	"encoding/json"
	"errors"
	"net/netip"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/metacubex/mihomo/component/resolver"
	D "github.com/miekg/dns"
	"golang.org/x/net/idna"

	"clashpseudo/native/internal/appcontract"
)

const MaxDNSRequest = appcontract.DnsRequestBytes
const MaxDNSResult = appcontract.DnsResultBytes
const MaxDNSRecords = appcontract.DnsResultRecords

var dnsTypes = map[string]uint16{"A": D.TypeA, "AAAA": D.TypeAAAA, "CNAME": D.TypeCNAME, "MX": D.TypeMX,
	"TXT": D.TypeTXT, "NS": D.TypeNS, "SOA": D.TypeSOA, "PTR": D.TypePTR, "SRV": D.TypeSRV,
	"HTTPS": D.TypeHTTPS, "SVCB": D.TypeSVCB, "CAA": D.TypeCAA}

type DNSQuestion struct {
	Name string `json:"name"`
	Type string `json:"type"`
}
type dnsRecord struct {
	Name  string `json:"name"`
	Type  string `json:"type"`
	Class string `json:"class"`
	TTL   uint32 `json:"ttl"`
	Data  string `json:"data"`
}
type dnsReply struct {
	Question   DNSQuestion `json:"question"`
	Rcode      int         `json:"rcode"`
	RcodeName  string      `json:"rcodeName"`
	ElapsedMS  float64     `json:"elapsedMs"`
	Truncated  bool        `json:"truncated"`
	Answer     []dnsRecord `json:"answer"`
	Authority  []dnsRecord `json:"authority"`
	Additional []dnsRecord `json:"additional"`
	Stale      bool        `json:"stale,omitempty"`
	Error      string      `json:"error,omitempty"`
	Detail     string      `json:"detail,omitempty"`
}

type dnsOperation struct {
	kind      string
	requestID uint64
	owner     *socketOwner
	epoch     uint64
	system    func()
	ctx       context.Context
	cancel    context.CancelFunc
}

// The actual public call owns this slot until return; Stop waits through its update
// lifetime.
func (e *Engine) beginDNS(kind string, requestID uint64, parents ...context.Context) (*dnsOperation, resolver.Resolver, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return nil, nil, errors.New("unavailable")
	}
	if kind == "query" && (!e.cfg.DNS.Enable || resolver.DefaultResolver == nil) {
		return nil, nil, errors.New("unavailable")
	}
	parent := context.Background()
	if len(parents) != 0 {
		parent = parents[0]
	}
	ctx, cancel := context.WithTimeout(parent, appcontract.DnsQueryTimeoutMs*time.Millisecond)
	op := &dnsOperation{kind: kind, requestID: requestID, owner: e.owner, epoch: e.networkEpoch.Load(), system: e.systemDNS.CaptureCache(e.owner.id), ctx: ctx, cancel: cancel}
	if !e.dnsOperation.CompareAndSwap(nil, op) {
		cancel()
		return nil, nil, errors.New("busy")
	}
	e.updates.Add(1)
	return op, resolver.DefaultResolver, nil
}
func (e *Engine) endDNS(op *dnsOperation) {
	op.cancel()
	e.dnsOperation.CompareAndSwap(op, nil)
	e.updates.Done()
}
func (e *Engine) CancelDNSRequest(id uint64) {
	if id == 0 {
		return
	}
	if op := e.dnsOperation.Load(); op != nil && op.kind == "query" && op.requestID == id {
		op.cancel()
	}
}

func (e *Engine) CancelDNSQuery() {
	if op := e.dnsOperation.Load(); op != nil && op.kind == "query" {
		op.cancel()
	}
}
func (e *Engine) dnsCurrent(op *dnsOperation) bool {
	return current.Load() == op.owner && op.owner.active.Load() && e.networkEpoch.Load() == op.epoch
}
func dnsFailure(code string, cause ...error) string {
	// Keep the complete diagnostic even when it exceeds the result budget. The
	// bridge must then reject the whole envelope through failure.details, not
	// accept a larger result or trim the cause to manufacture a bounded success.
	value := map[string]string{"error": code}
	if err := errors.Join(cause...); err != nil {
		value["detail"] = err.Error()
	}
	body, _ := json.Marshal(value)
	return string(body)
}

func normalizeDNSQuestion(body []byte) (DNSQuestion, uint16, error) {
	var q DNSQuestion
	if len(body) == 0 || len(body) > MaxDNSRequest {
		return q, 0, errors.New("DNS request is empty or exceeds its byte limit")
	}
	if !utf8.Valid(body) {
		return q, 0, errors.New("DNS request is not valid UTF-8")
	}
	if err := json.Unmarshal(body, &q); err != nil {
		return q, 0, err
	}
	if q.Name == "" || len(q.Name) > appcontract.DnsNameBytes || !utf8.ValidString(q.Name) {
		return q, 0, errors.New("DNS name is empty, exceeds its byte limit or is not valid UTF-8")
	}
	q.Type = strings.ToUpper(q.Type)
	kind, ok := dnsTypes[q.Type]
	if !ok {
		return q, 0, errors.New("unsupported DNS question type: " + q.Type)
	}
	if kind == D.TypePTR {
		if ip, err := netip.ParseAddr(q.Name); err == nil {
			name, err := D.ReverseAddr(ip.String())
			q.Name = name
			return q, kind, err
		}
	}
	// The fixed packer narrows decimal escapes to a byte. Check that one
	// representation gap here; the library still owns DNS label/wire grammar.
	for index := 0; index < len(q.Name); index++ {
		if q.Name[index] != '\\' {
			continue
		}
		index++
		if index >= len(q.Name) {
			break
		}
		if q.Name[index] >= '0' && q.Name[index] <= '9' {
			if index+3 > len(q.Name) {
				return q, 0, errors.New("incomplete decimal DNS escape")
			}
			if _, err := strconv.ParseUint(q.Name[index:index+3], 10, 8); err != nil {
				return q, 0, err
			}
			index += 2
		}
	}
	name := q.Name
	if !strings.ContainsRune(name, '\\') {
		name = strings.NewReplacer("。", ".", "．", ".", "｡", ".").Replace(name)
	}
	// Ordinary Unicode labels keep lookup IDNA conversion. An explicitly
	// escaped DNS presentation is instead handled as-is by the DNS library;
	// splitting it on dots would change escaped label boundaries.
	if !strings.ContainsRune(name, '\\') && strings.IndexFunc(name, func(r rune) bool { return r > 127 }) >= 0 {
		profile := idna.New(idna.MapForLookup(), idna.StrictDomainName(false))
		labels := strings.Split(name, ".")
		for index, label := range labels {
			if strings.IndexFunc(label, func(r rune) bool { return r > 127 }) < 0 {
				continue
			}
			ascii, err := profile.ToASCII(label)
			if err != nil {
				return q, 0, err
			}
			labels[index] = ascii
		}
		name = strings.Join(labels, ".")
	}
	q.Name = D.Fqdn(name)
	var wire [256]byte
	length, err := D.PackDomainName(q.Name, wire[:], 0, nil, false)
	if err != nil {
		return q, 0, err
	}
	if length > 255 {
		return q, 0, errors.New("DNS wire name exceeds 255 bytes")
	}
	return q, kind, nil
}

func (e *Engine) DNSQueryContext(ctx context.Context, body []byte) string {
	q, kind, err := normalizeDNSQuestion(body)
	if err != nil {
		return dnsFailure("invalidRequest", err)
	}
	var token struct {
		RequestID json.RawMessage `json:"requestId"`
	}
	if err := json.Unmarshal(body, &token); err != nil {
		return dnsFailure("invalidRequest", err)
	}
	var id uint64
	if len(token.RequestID) != 0 {
		value := strings.Trim(string(token.RequestID), "\"")
		id, err = strconv.ParseUint(value, 10, 64)
		if err != nil {
			return dnsFailure("invalidRequest", err)
		}
	}
	op, source, err := e.beginDNS("query", id, ctx)
	if err != nil {
		return dnsFailure(err.Error())
	}
	defer e.endDNS(op)
	if op.ctx.Err() != nil {
		return dnsFailure("cancelled")
	}
	request := new(D.Msg)
	request.SetQuestion(q.Name, kind)
	started := time.Now()
	answer, err := source.ExchangeContext(op.ctx, request)
	elapsed := time.Since(started)
	code := ""
	if err != nil {
		code = "queryFailed"
		if errors.Is(err, context.DeadlineExceeded) {
			code = "timeout"
		} else if errors.Is(err, context.Canceled) {
			code = "cancelled"
		}
		if answer == nil {
			return dnsFailure(code, err)
		}
	}
	if answer == nil {
		return dnsFailure("queryFailed", errors.New("DNS resolver returned no message"))
	}
	if len(answer.Answer)+len(answer.Ns)+len(answer.Extra) > MaxDNSRecords {
		return dnsFailure("resultTooLarge", err)
	}
	project := func(records []D.RR) []dnsRecord {
		out := make([]dnsRecord, 0, len(records))
		for _, rr := range records {
			h := rr.Header()
			out = append(out, dnsRecord{Name: h.Name, Type: D.Type(h.Rrtype).String(), Class: D.Class(h.Class).String(), TTL: h.Ttl, Data: strings.TrimPrefix(rr.String(), h.String())})
		}
		return out
	}
	value := dnsReply{Question: q, Rcode: answer.Rcode, RcodeName: D.RcodeToString[answer.Rcode], ElapsedMS: float64(elapsed) / float64(time.Millisecond), Truncated: answer.Truncated,
		Answer: project(answer.Answer), Authority: project(answer.Ns), Additional: project(answer.Extra), Stale: !e.dnsCurrent(op), Error: code}
	if err != nil {
		value.Detail = err.Error()
	}
	if value.RcodeName == "" {
		value.RcodeName = "RCODE" + strconv.Itoa(answer.Rcode)
	}
	encoded, marshalError := json.Marshal(value)
	if marshalError != nil {
		return dnsFailure("queryFailed", err, marshalError)
	}
	if len(encoded) > MaxDNSResult {
		return dnsFailure("resultTooLarge", err)
	}
	return string(encoded)
}

func (e *Engine) ClearDNSCache() string {
	op, source, err := e.beginDNS("cache", 0)
	if err != nil {
		return dnsFailure(err.Error())
	}
	defer e.endDNS(op)
	system := op.system
	activeSystem := system != nil
	if source != nil {
		source.ClearCache()
	}
	if activeSystem {
		system()
	}
	status := "empty"
	if source != nil || activeSystem {
		status = "completed"
	}
	value, _ := json.Marshal(map[string]any{"status": status, "resolverActive": source != nil, "systemResolverActive": activeSystem, "stale": !e.dnsCurrent(op)})
	return string(value)
}

type fakeIPFamily struct {
	Active  bool   `json:"active"`
	Outcome string `json:"outcome"`
}

func (e *Engine) FlushFakeIP() string {
	op, _, err := e.beginDNS("cache", 0)
	if err != nil {
		return dnsFailure(err.Error())
	}
	defer e.endDNS(op)
	e.mu.Lock()
	v4, v6 := e.cfg.DNS.FakeIPPool != nil, e.cfg.DNS.FakeIPPool6 != nil
	persistent := e.cfg.Profile.StoreFakeIP
	e.mu.Unlock()
	status := "empty"
	outcome := "inactive"
	var failure error
	if v4 || v6 {
		status, outcome = "completed", "cleared"
		if failure = resolver.FlushFakeIP(); failure != nil {
			status, outcome = "partialOrFailed", "unconfirmed"
		}
	}
	family := func(active bool) fakeIPFamily {
		if !active {
			return fakeIPFamily{false, "inactive"}
		}
		return fakeIPFamily{true, outcome}
	}
	// Preserve each completed flush mutation and report later cancellation or aggregate
	// partial failure separately.
	result := map[string]any{"status": status, "persistent": persistent, "ipv4": family(v4), "ipv6": family(v6), "stale": !e.dnsCurrent(op)}
	if failure != nil {
		result["detail"] = failure.Error()
	}
	value, _ := json.Marshal(result)
	return string(value)
}
