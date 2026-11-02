package engine

import (
	"fmt"
	"github.com/metacubex/mihomo/component/geodata"
	C "github.com/metacubex/mihomo/constant"
)

// 公开getter在parser/provider启动前读取，并保留本次实际路径。
func geoFiles() [4]string {
	return [4]string{C.Path.GeoIP(), C.Path.MMDB(), C.Path.ASN(), C.Path.GeoSite()}
}

type geoResource struct {
	name, path, source string
	autoUpdateTarget   bool
}

func (e *Engine) capturePathsLocked(home string) error {
	if home == "" {
		home = e.pathsHome
		if home == "" {
			home = C.Path.HomeDir()
		}
	}
	if e.pathsHome != "" {
		if e.pathsHome != home {
			return fmt.Errorf("core home is already captured as %q", e.pathsHome)
		}
		return nil
	}
	C.SetHomeDir(home)
	e.pathsHome = home
	e.geoPaths = geoFiles()
	e.cachePath = C.Path.Cache()
	return nil
}
func (e *Engine) Paths(home string) (map[string]string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.pathsHome == "" && e.used {
		return nil, ErrStopped
	}
	if err := e.capturePathsLocked(home); err != nil {
		return nil, err
	}
	return map[string]string{"cache": e.cachePath, "geoip": e.geoPaths[0], "mmdb": e.geoPaths[1], "asn": e.geoPaths[2], "geosite": e.geoPaths[3]}, nil
}

func (e *Engine) geoResourcesLocked() [4]geoResource {
	ip, mode := geodata.GeoIpEnable(), geodata.GeodataMode()
	return [4]geoResource{
		{"GeoIP", e.geoPaths[0], geodata.GeoIpUrl(), ip && mode},
		{"MMDB", e.geoPaths[1], geodata.MmdbUrl(), ip && !mode},
		{"GeoSite", e.geoPaths[3], geodata.GeoSiteUrl(), geodata.GeoSiteEnable()},
		{"ASN", e.geoPaths[2], geodata.ASNUrl(), geodata.ASNEnable()},
	}
}
