//go:build linux && !android

package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/memory"
)

func TestProcessMemoryUsesPublicResidentPagesAndKeepsFailuresUnavailable(t *testing.T) {
	var sample processMemorySample
	if err := json.Unmarshal([]byte(ProcessMemory()), &sample); err != nil || !sample.Valid || sample.Bytes == nil || *sample.Bytes == 0 || sample.Error != "" || sample.SampledAt <= 0 {
		t.Fatalf("real process memory unavailable: %+v %v", sample, err)
	}
	// Compare RSS with a near-time independent proc observation.
	body, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(os.Getpid()), "statm"))
	if err != nil {
		t.Fatal(err)
	}
	fields := strings.Fields(string(body))
	pages, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		t.Fatal(err)
	}
	near := pages * uint64(os.Getpagesize())
	difference := int64(near) - int64(*sample.Bytes)
	if difference < -16<<20 || difference > 16<<20 {
		t.Fatalf("RSS not near independent same-process resident pages: %d vs %d", *sample.Bytes, near)
	}
	for _, read := range []func(int32) (*memory.MemoryInfoStat, error){
		func(pid int32) (*memory.MemoryInfoStat, error) {
			if pid != int32(os.Getpid()) {
				t.Fatal("wrong process")
			}
			return nil, errors.New("private path must not escape")
		},
		func(int32) (*memory.MemoryInfoStat, error) { return nil, nil },
	} {
		if err := json.Unmarshal([]byte(processMemory(read)), &sample); err != nil || sample.Valid || sample.Bytes != nil || sample.Error != "unavailable" {
			t.Fatalf("failure was zero or retained prior RSS: %+v %v", sample, err)
		}
	}
}
