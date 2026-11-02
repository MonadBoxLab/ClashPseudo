package coreview

import (
	P "github.com/metacubex/mihomo/constant/provider"
	"testing"
)

func TestProviderUpdatePolicyKeepsConfiguredUnitsAndInlineUnavailable(t *testing.T) {
	for _, fixture := range []struct {
		vehicle P.VehicleType
		seconds int
		auto    bool
	}{
		{P.HTTP, 3600, true}, {P.HTTP, 0, false}, {P.File, 0, true}, {P.Inline, 0, false},
	} {
		var entry Resource
		providerUpdatePolicy(&entry, fixture.vehicle, fixture.seconds)
		if fixture.vehicle == P.Inline {
			if entry.AutoUpdate != nil || entry.UpdateIntervalSeconds != nil {
				t.Fatalf("inline provider advertised an external update policy: %+v", entry)
			}
			continue
		}
		if entry.AutoUpdate == nil || *entry.AutoUpdate != fixture.auto {
			t.Fatalf("configured automatic policy = %+v", entry)
		}
		if fixture.vehicle == P.HTTP && (entry.UpdateIntervalSeconds == nil || *entry.UpdateIntervalSeconds != fixture.seconds) {
			t.Fatalf("HTTP interval not in seconds: %+v", entry)
		}
		if fixture.vehicle == P.File && entry.UpdateIntervalSeconds != nil {
			t.Fatal("file watcher represented as a polling interval")
		}
	}
}
