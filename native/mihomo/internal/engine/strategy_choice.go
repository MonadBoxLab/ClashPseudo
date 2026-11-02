package engine

import (
	"encoding/json"
	"errors"
)

type Choice struct {
	Type   string  `json:"type"`
	Member *string `json:"member"`
}

func DecodeChoice(data []byte) (Choice, error) {
	var fields map[string]json.RawMessage
	var choice Choice
	if json.Unmarshal(data, &fields) != nil || fields["member"] == nil || json.Unmarshal(data, &choice) != nil || !choice.valid() {
		return Choice{}, errors.New("invalid strategy choice")
	}
	return choice, nil
}

func (c Choice) valid() bool {
	if c.Type != "select" && c.Type != "url-test" && c.Type != "fallback" {
		return false
	}
	return (c.Member == nil && c.Type != "select") || (c.Member != nil && *c.Member != "")
}
