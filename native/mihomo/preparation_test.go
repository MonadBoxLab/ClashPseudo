package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func TestPreparationOptionsAcceptEncodedBoundaryWithoutTruncating(t *testing.T) {
	prefix := []byte(`{"purpose":"PREVIEW","composition":"`)
	suffix := []byte(`"}`)
	body := append(bytes.Clone(prefix), bytes.Repeat([]byte("x"), maxPreparationOptions-len(prefix)-len(suffix))...)
	body = append(body, suffix...)
	if len(body) != maxPreparationOptions {
		t.Fatal("fixture does not reach the wire boundary")
	}
	options, err := decodePreparationOptions(body)
	if err != nil || len(options.Composition) != maxPreparationOptions-len(prefix)-len(suffix) {
		t.Fatalf("boundary was rejected or truncated: %v", err)
	}
	larger := append(bytes.Clone(body[:len(body)-2]), 'x', '"', '}')
	if len(larger) != maxPreparationOptions+1 || !json.Valid(larger) {
		t.Fatal("overflow fixture must still be valid JSON")
	}
	if _, err := decodePreparationOptions(larger); err == nil {
		t.Fatal("encoded budget overflow was accepted")
	}
}

func TestPreparationOptionsKeepLargeCompleteCompositionAndEscapedMetadata(t *testing.T) {
	identity := []any{"main", 7}
	for index := 0; index < 4096; index++ {
		identity = append(identity, []any{fmt.Sprintf("plugin-%04d-%s", index, strings.Repeat("identity", 8)), index + 1, "prepend"})
	}
	composition, err := json.Marshal(identity)
	if err != nil {
		t.Fatal(err)
	}
	name := "quoted \" \\ \x00 \n 配置 🌐"
	encoded, err := json.Marshal(map[string]any{
		"purpose": "VPN", "generation": 10, "composition": string(composition),
		"mainOrigin": map[string]any{"id": "main", "revision": 7, "name": name},
	})
	if err != nil || len(encoded) <= 64<<10 || len(encoded) >= maxPreparationOptions {
		t.Fatal("fixture must exceed the old small-buffer assumption")
	}
	options, err := decodePreparationOptions(encoded)
	if err != nil || options.Composition != string(composition) || options.MainOrigin.Name != name || options.Generation != 10 {
		t.Fatal("large composition or escaped source metadata changed")
	}
	var decoded []json.RawMessage
	if json.Unmarshal([]byte(options.Composition), &decoded) != nil || len(decoded) != 4098 {
		t.Fatal("plugin identities were truncated or replaced with another identity protocol")
	}
}

func TestPreparationOptionsCountUTF8AndJSONEscapesRatherThanRunes(t *testing.T) {
	for _, unit := range []string{"界", "🌐", "\x00", "\"", "\\"} {
		t.Run(fmt.Sprintf("unit-%x", []byte(unit)), func(t *testing.T) {
			base, _ := json.Marshal(map[string]string{"purpose": "PREVIEW", "composition": ""})
			one, _ := json.Marshal(unit)
			width := len(one) - 2
			count := (maxPreparationOptions - len(base)) / width
			body, _ := json.Marshal(map[string]string{"purpose": "PREVIEW", "composition": strings.Repeat(unit, count)})
			if len(body) > maxPreparationOptions {
				t.Fatal("fixture exceeds budget")
			}
			options, err := decodePreparationOptions(body)
			if err != nil || options.Composition != strings.Repeat(unit, count) {
				t.Fatal("valid encoded input changed")
			}
			body, _ = json.Marshal(map[string]string{"purpose": "PREVIEW", "composition": strings.Repeat(unit, count+1)})
			if len(body) <= maxPreparationOptions {
				t.Fatal("fixture must exceed encoded budget")
			}
			if _, err := decodePreparationOptions(body); err == nil {
				t.Fatal("encoding expansion escaped the limit")
			}
		})
	}
}

func TestPreparationOptionsRejectInvalidUTF8ObjectAndJSON(t *testing.T) {
	for _, body := range [][]byte{
		nil, []byte(" "), []byte("null"), []byte("[]"), []byte(`{"purpose":`),
		[]byte(`{"purpose":"PREVIEW"} {}`),
		append([]byte(`{"composition":"`), 0xff, '"', '}'),
	} {
		if _, err := decodePreparationOptions(body); err == nil || err.Error() != "invalid native preparation options" {
			t.Fatal("invalid preparation options were accepted or leaked raw parse details")
		}
	}
}
