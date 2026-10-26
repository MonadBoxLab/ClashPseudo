package engine

import (
	"context"
	"os"
	"sync"
	"time"

	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/component/resource"
	C "github.com/metacubex/mihomo/constant"

	"github.com/oschwald/maxminddb-golang"
)

// geoUpdater owns a session ticker and invokes public per-database refresh operations
// for enabled targets.
type geoUpdater struct {
	cancel chan struct{}
	done   chan struct{}
	once   sync.Once
}

func (g *geoUpdater) cancelUpdates() {
	g.once.Do(func() { close(g.cancel) })
}

func (g *geoUpdater) stop() {
	g.cancelUpdates()
	// Keep session ownership and global database paths stable through the actual upstream
	// write's return.
	<-g.done
}

// updateMaxMind fills the public updater's first-install gap only. In fixed
// mihomo v1.19.32 UpdateMMDB/UpdateASN unconditionally open and close the old
// reader before writing, which fatally exits for a missing or corrupt old file.
// Reuse its public HTTP vehicle, the same public validator, and write operation
// for that case; ordinary valid-database updates stay on the upstream entry.
// The caller must hold the session's update admission until this returns.
func updateMaxMind(source, path string, update func() error, reload func()) error {
	if mmdb.Verify(path) {
		return update()
	}
	// Default rule routing can itself consult the missing database. Only this
	// bootstrap branch is explicitly direct; valid-database updates retain the
	// upstream updater's normal routing and TLS behavior.
	vehicle := resource.NewHTTPVehicle(source, path, "DIRECT", nil, 90*time.Second, 0)
	data, _, err := vehicle.Read(context.Background(), utils.HashType{})
	if err != nil {
		return err
	}
	reader, err := maxminddb.FromBytes(data)
	if err != nil {
		return err
	}
	if err := reader.Close(); err != nil {
		return err
	}
	if err := vehicle.Write(data); err != nil {
		return err
	}
	reload()
	return nil
}

// geoUpdateState is bounded to the four supported databases in the current
// session. A successful public call may only have checked unchanged content;
// none of these times claims a download or a file replacement took place.
type geoUpdateState struct {
	LastAttempt         time.Time
	LastResult          string
	LastSuccessfulCheck time.Time
}

// Called with e.mu held, like the resource projection that consumes it.
func (e *Engine) geoUpdateStateLocked(name string) geoUpdateState {
	return e.geoResults[name]
}

// Called with e.mu held, and only for a validated, individual Geo target.
// The surrounding resource admission owns the real operation until it returns.
func (e *Engine) observeGeoUpdateLocked(name string, update func() error) func() error {
	owner := e.owner
	return func() error {
		e.mu.Lock()
		if e.owner != owner || !e.available() {
			e.mu.Unlock()
			return ErrStopped
		}
		if e.geoResults == nil {
			e.geoResults = make(map[string]geoUpdateState, 4)
		}
		state := e.geoResults[name]
		state.LastAttempt = time.Now()
		state.LastResult = ""
		e.geoResults[name] = state
		e.mu.Unlock()

		err := update()
		e.mu.Lock()
		defer e.mu.Unlock()
		if e.owner != owner || !e.available() {
			return ErrStopped
		}
		state.LastResult = "failed"
		if err == nil {
			state.LastResult = "success"
			state.LastSuccessfulCheck = time.Now()
		}
		e.geoResults[name] = state
		return err
	}
}

// Used only during controlled preparation, before providers start. The public
// getters mutate mihomo's global names even when the resolved path is unchanged.
func geoFiles() [4]string {
	return [4]string{C.Path.GeoIP(), C.Path.MMDB(), C.Path.ASN(), C.Path.GeoSite()}
}

type geoResource struct {
	name, path, source string
	autoUpdateTarget   bool
}

// With e.mu held, read process-wide update-target flags, including retained
// prior-session usage. Diagnostics and scheduling use this same target scope.
func (e *Engine) geoResourcesLocked() [4]geoResource {
	ip, mode := geodata.GeoIpEnable(), geodata.GeodataMode()
	return [4]geoResource{
		{"GeoIP", e.geoPaths[0], geodata.GeoIpUrl(), ip && mode},
		{"MMDB", e.geoPaths[1], geodata.MmdbUrl(), ip && !mode},
		{"GeoSite", e.geoPaths[3], geodata.GeoSiteUrl(), geodata.GeoSiteEnable()},
		{"ASN", e.geoPaths[2], geodata.ASNUrl(), geodata.ASNEnable()},
	}
}

// Revalidate current file existence and contents after a recent successful
// unchanged-content check.
func geoResourceDue(item geoResource, interval time.Duration, lastCheck, now time.Time) bool {
	info, err := os.Stat(item.path)
	if err != nil || !info.Mode().IsRegular() {
		return true
	}
	last := info.ModTime()
	if lastCheck.After(last) {
		last = lastCheck
	}
	if !last.Add(interval).After(now) {
		return true
	}
	if item.name == "MMDB" || item.name == "ASN" {
		return !mmdb.Verify(item.path)
	}
	data, err := os.ReadFile(item.path)
	if err != nil {
		return true
	}
	loader, err := geodata.GetGeoDataLoader("standard")
	if err != nil {
		return true
	}
	if item.name == "GeoIP" {
		_, err = loader.LoadIPByBytes(data, "cn")
	} else {
		_, err = loader.LoadSiteByBytes(data, "cn")
	}
	return err != nil
}

// startGeo begins the timer described by geo-auto-update and
// geo-update-interval. It must be called with the engine lock held after a
// successful Prepare.
func (e *Engine) startGeo(enabled bool, hours int) {
	if !enabled || hours <= 0 {
		return
	}
	interval := time.Duration(hours) * time.Hour
	g := &geoUpdater{cancel: make(chan struct{}), done: make(chan struct{})}
	e.geo = g
	go func() {
		defer close(g.done)
		update := func() {
			select {
			case <-g.cancel:
				return
			default:
			}
			// Use the same serialized admission as manual updates. Stop invalidates
			// admission and waits for the real public updater call to finish.
			// Failures leave the existing database usable; the next tick retries.
			_ = e.updateResource("geo", "", true)
		}
		// The serialized operation checks freshness and validity per core target,
		// both on startup and on subsequent ticks.
		update()
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-g.cancel:
				return
			case <-ticker.C:
				update()
			}
		}
	}()
}

// takeGeo detaches the scheduler under the engine lock. The caller must wait
// for it after releasing the lock so an in-flight database write finishes
// before a new session changes the global paths.
func (e *Engine) takeGeo() *geoUpdater {
	g := e.geo
	e.geo = nil
	return g
}
