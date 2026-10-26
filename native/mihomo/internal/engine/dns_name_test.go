package engine

import (
	"encoding/json"
	"strings"
	"testing"

	D "github.com/miekg/dns"
)

func TestDNSOwnerNamesUseDNSGrammarAcrossRecordTypes(t *testing.T) {
	for _, kind := range []string{"A", "AAAA", "CNAME", "MX", "TXT", "NS", "SOA", "PTR", "SRV", "HTTPS", "SVCB", "CAA"} {
		for _, name := range []string{"_", "__owner", "some_owner.example", "_service._tcp._zone.example", "-owner.example", "owner-.example", "*.example", "."} {
			t.Run(kind+"/"+name, func(t *testing.T) {
				q, code, err := normalizeDNSQuestion(questionJSON(name, strings.ToLower(kind)))
				if err != nil || q.Type != kind || code != dnsTypes[kind] || q.Name != D.CanonicalName(name) {
					t.Fatalf("a valid owner was restricted as a host: type=%s name=%q err=%v", kind, name, err)
				}
				msg := new(D.Msg)
				msg.SetQuestion(q.Name, code)
				wire, err := msg.Pack()
				if err != nil {
					t.Fatal(err)
				}
				var decoded D.Msg
				if decoded.Unpack(wire) != nil || len(decoded.Question) != 1 || decoded.Question[0].Name != q.Name {
					t.Fatal("the actual DNS question was changed during wire packing")
				}
			})
		}
	}
}

func TestDNSNamesKeepLookupIDNACanonicalCaseAndExplicitEscapes(t *testing.T) {
	for _, item := range []struct{ name, kind, expected string }{
		{"BÜCHER。Example", "A", "xn--bcher-kva.example."},
		{"_service.BÜCHER.example", "SRV", "_service.xn--bcher-kva.example."},
		{`one\.label.Example`, "TXT", `one\.label.example.`},
		{`one\046label.Example`, "TXT", `one\046label.example.`},
		{"192.0.2.1", "PTR", "1.2.0.192.in-addr.arpa."},
		{"_services._dns-sd._udp.local", "PTR", "_services._dns-sd._udp.local."},
		{"32-63.2.0.192.in-addr.arpa", "PTR", "32-63.2.0.192.in-addr.arpa."},
	} {
		t.Run(item.name, func(t *testing.T) {
			q, _, err := normalizeDNSQuestion(questionJSON(item.name, item.kind))
			if err != nil || q.Name != item.expected {
				t.Fatalf("normalization: got=%q want=%q err=%v", q.Name, item.expected, err)
			}
		})
	}
	name := strings.Repeat("ä", 40) + ".example"
	if _, _, err := normalizeDNSQuestion(questionJSON(name, "A")); err != nil {
		t.Fatal("UTF-8 label length must not reject a valid shorter IDNA wire name")
	}
}

func TestDNSOwnerWireAndInputBudgetsAreIndependent(t *testing.T) {
	maximum := strings.Repeat("a", 63) + "." + strings.Repeat("b", 63) + "." + strings.Repeat("c", 63) + "." + strings.Repeat("d", 61)
	q, _, err := normalizeDNSQuestion(questionJSON(maximum, "TXT"))
	if err != nil {
		t.Fatal(err)
	}
	var wire [256]byte
	length, err := D.PackDomainName(q.Name, wire[:], 0, nil, false)
	if err != nil || length != 255 {
		t.Fatal("the actual maximum wire name was not accepted")
	}
	for _, name := range []string{maximum + "d", strings.Repeat("a", 64) + ".example", strings.Repeat("a", 1025)} {
		if _, _, err := normalizeDNSQuestion(questionJSON(name, "TXT")); err == nil {
			t.Fatal("a raw or wire name overflow was accepted")
		}
	}
	body := questionJSON("owner.example", "TXT")
	body = append(body, []byte(strings.Repeat(" ", MaxDNSRequest+1-len(body)))...)
	if !json.Valid(body) {
		t.Fatal("request overflow fixture must remain valid JSON")
	}
	if _, _, err := normalizeDNSQuestion(body); err == nil {
		t.Fatal("raw request budget was not enforced")
	}
}

func TestDNSOwnerBadLabelsInjectionAndEncodingRemainRejected(t *testing.T) {
	for _, name := range []string{"", ".owner.example", "one..example", "owner..", "owner\nTXT injected", "owner\r.example", "owner\t.example", "owner example", "https://owner.example", "owner@example", `trailing\`, `bad\999.example`, `bad\256.example`, `bad\12.example`, `bad\12x.example`} {
		if _, _, err := normalizeDNSQuestion(questionJSON(name, "TXT")); err == nil {
			t.Errorf("invalid owner was accepted: %q", name)
		}
	}
	invalid := append([]byte(`{"name":"`), 0xff)
	invalid = append(invalid, []byte(`","type":"A"}`)...)
	if _, _, err := normalizeDNSQuestion(invalid); err == nil {
		t.Fatal("invalid UTF-8 was accepted")
	}
	if _, _, err := normalizeDNSQuestion(questionJSON("owner.example", "AXFR")); err == nil {
		t.Fatal("unsupported record type was accepted")
	}
}
