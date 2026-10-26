package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"unicode/utf8"

	"clashpseudo/native/internal/appcontract"
	"clashpseudo/native/internal/engine"
)

// This is the UTF-8 JSON wire budget, independent of body and fragment budgets.
const maxPreparationOptions = appcontract.ConfigurationPreparationOptionsBytes

func decodePreparationOptions(body []byte) (engine.PrepareOptions, error) {
	var options engine.PrepareOptions
	if len(body) == 0 || len(body) > maxPreparationOptions {
		return options, errors.New("invalid native preparation options")
	}
	object := bytes.TrimSpace(body)
	if !utf8.Valid(body) || len(object) == 0 || object[0] != '{' || json.Unmarshal(body, &options) != nil {
		return engine.PrepareOptions{}, errors.New("invalid native preparation options")
	}
	return options, nil
}
