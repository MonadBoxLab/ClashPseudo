// Package engine owns one embedded mihomo session. Calls that mutate it are serialized.
package engine

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"syscall"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// Android builds inject the version resolved from go.mod.
var Version = "development"

var ErrStopped = errors.New("native session is not accepting sockets")

type socketOwner struct {
	active   atomic.Bool
	protect  func(int) bool
	accepted atomic.Uint64
	refused  atomic.Uint64
}

var current atomic.Pointer[socketOwner]

func init() {
	// Dialers read this hook concurrently. Keep the function stable and switch
	// only its atomic owner, so stopping cannot race a function-pointer change.
	dialer.DefaultSocketHook = func(_, _ string, raw syscall.RawConn) error {
		owner := current.Load()
		if owner == nil || !owner.active.Load() {
			return ErrStopped
		}
		var protectErr error
		err := raw.Control(func(fd uintptr) {
			if !owner.active.Load() || !owner.protect(int(fd)) {
				owner.refused.Add(1)
				protectErr = errors.New("VpnService.protect refused socket")
				return
			}
			owner.accepted.Add(1)
		})
		return errors.Join(err, protectErr)
	}
}

type Engine struct {
	mu     sync.Mutex
	cfg    *config.Config
	tun    io.Closer
	owner  *socketOwner
	failed bool
}

func (e *Engine) Prepare(home string, body []byte, protect func(int) bool) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.owner != nil || e.failed {
		return errors.New("native session is busy or cleanup is unconfirmed")
	}
	if protect == nil {
		return errors.New("socket protector is required")
	}
	raw, err := config.UnmarshalRawConfig(body)
	if err != nil {
		return err
	}
	if err = configurePlatform(raw, home); err != nil {
		return err
	}
	owner := &socketOwner{protect: protect}
	owner.active.Store(true)
	if !current.CompareAndSwap(nil, owner) {
		return errors.New("another native session exists")
	}
	e.owner = owner
	C.SetHomeDir(home)
	C.Version = Version
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		owner.active.Store(false)
		current.CompareAndSwap(owner, nil)
		e.owner = nil
		return err
	}
	e.cfg = cfg
	executor.ApplyConfig(cfg, true)
	if !owner.active.Load() {
		return errors.Join(ErrStopped, e.stopLocked())
	}
	return nil
}

// Cancel invalidates pending preparation without waiting for provider I/O.
// The caller must still call Stop and await its result before starting again.
func (e *Engine) Cancel() {
	if owner := current.Load(); owner != nil {
		owner.active.Store(false)
	}
}

func (e *Engine) Stop() error {
	e.Cancel()
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.stopLocked()
}

func (e *Engine) stopLocked() error {
	tunnel.OnSuspend()
	var errs []error
	if e.tun != nil {
		errs = append(errs, e.tun.Close())
		e.tun = nil
	}
	if e.cfg != nil {
		// Provider Close cancels background I/O; it does not join its goroutines.
		for _, p := range e.cfg.Providers {
			errs = append(errs, closeResource(p))
		}
		for _, p := range e.cfg.RuleProviders {
			errs = append(errs, closeResource(p))
		}
		statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
			err := c.Close()
			if err != nil && !errors.Is(err, net.ErrClosed) {
				errs = append(errs, err)
			}
			return true
		})
		// Provider Close stops refresh/health checks, not the nodes it owns.
		// Parsed nodes use upstream's once-only Close wrapper, including nodes
		// shared with the main proxy map. Provider cancellation is not a join.
		for _, provider := range e.cfg.Providers {
			for _, p := range provider.Proxies() {
				errs = append(errs, p.Close())
			}
		}
		for _, p := range e.cfg.Proxies {
			errs = append(errs, p.Close())
		}
		dns.ReCreateServer("", nil, nil)
		resolver.ResetConnection()
		resolver.DefaultResolver = nil
		resolver.DefaultHostMapper = nil
		resolver.DefaultService = nil
		resolver.ProxyServerHostResolver = nil
		resolver.DirectHostResolver = nil
		// Release session state without shutting down mihomo's process-wide runtime.
		tunnel.UpdateProxies(nil, nil)
		tunnel.UpdateRules(nil, nil, nil)
		e.cfg = nil
	}
	if e.owner != nil {
		current.CompareAndSwap(e.owner, nil)
		e.owner = nil
	}
	err := errors.Join(errs...)
	if e.failed && err == nil {
		err = errors.New("previous native cleanup is still unconfirmed")
	}
	if err != nil {
		e.failed = true
	}
	return err
}

func closeResource(value any) error {
	closer, ok := value.(io.Closer)
	if !ok {
		return fmt.Errorf("resource %T has no explicit close operation", value)
	}
	return closer.Close()
}

func (e *Engine) Snapshot() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	var protected, refused uint64
	if e.owner != nil {
		protected = e.owner.accepted.Load()
		refused = e.owner.refused.Load()
	}
	data, _ := json.Marshal(struct {
		Version       string              `json:"version"`
		Prepared      bool                `json:"prepared"`
		Attached      bool                `json:"attached"`
		CleanupFailed bool                `json:"cleanupFailed"`
		Protected     uint64              `json:"protected"`
		Refused       uint64              `json:"refused"`
		Traffic       *statistic.Snapshot `json:"traffic"`
	}{Version, e.cfg != nil, e.tun != nil, e.failed, protected, refused, statistic.DefaultManager.Snapshot()})
	return string(data)
}
