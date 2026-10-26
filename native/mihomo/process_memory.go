package main

import (
	"encoding/json"
	"os"
	"time"

	"github.com/metacubex/mihomo/component/memory"
)

type processMemorySample struct {
	Bytes     *uint64 `json:"processRssBytes"`
	SampledAt int64   `json:"sampledAt"`
	Valid     bool    `json:"valid"`
	Error     string  `json:"error,omitempty"`
}

// ProcessMemory is independent of an Engine, VPN, and the Go heap. The public
// implementation uses resident pages times os.Getpagesize(), also on Android.
func ProcessMemory() string { return processMemory(memory.GetMemoryInfo) }

func processMemory(read func(int32) (*memory.MemoryInfoStat, error)) string {
	sample := processMemorySample{SampledAt: time.Now().UnixMilli()}
	value, err := read(int32(os.Getpid()))
	if err != nil || value == nil {
		sample.Error = "unavailable"
	} else {
		sample.Bytes, sample.Valid = &value.RSS, true
	}
	body, _ := json.Marshal(sample)
	return string(body)
}
