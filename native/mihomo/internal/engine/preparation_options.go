package engine

import (
	"context"
	"net/netip"
	"os"
	"path/filepath"

	"clashpseudo/native/internal/androidnet"
	"clashpseudo/native/internal/configinput"
)

type PrepareOptions struct {
	MainOrigin           configinput.ConfigOrigin                                 `json:"mainOrigin"`
	Purpose              string                                                   `json:"purpose"`
	Generation           int64                                                    `json:"generation"`
	Composition          string                                                   `json:"composition"`
	RoutingOverride      string                                                   `json:"routingOverride"`
	Network              androidnet.NetworkDNS                                    `json:"network"`
	VPNIntent            bool                                                     `json:"vpnIntent"`
	LANIntent            bool                                                     `json:"lanIntent"`
	ProtectNetwork       func(int, string) bool                                   `json:"-"`
	ProtectSocket        func(int) error                                          `json:"-"`
	ProtectOutbound      func(int, string) error                                  `json:"-"`
	SystemDNSQuery       func(context.Context, []byte) ([]byte, error)            `json:"-"`
	SystemLookup         func(context.Context, string, int) ([]netip.Addr, error) `json:"-"`
	SeedGeo              func([]GeoSeed) error                                    `json:"-"`
	SpecificationChanged func(uint64, bool)                                       `json:"-"`
}

type GeoSeed struct {
	Kind       string `json:"kind"`
	TargetName string `json:"targetName"`
}

func geoSeeds(paths [4]string, p configinput.Presence) ([]GeoSeed, error) {
	result := []GeoSeed{}
	for i, kind := range []string{"geoip", "mmdb", "asn", "geosite"} {
		if p.Has("geox-url." + kind) {
			continue
		}
		_, err := os.Lstat(paths[i])
		if os.IsNotExist(err) {
			result = append(result, GeoSeed{kind, filepath.Base(paths[i])})
		} else if err != nil {
			return nil, err
		}
	}
	return result, nil
}
