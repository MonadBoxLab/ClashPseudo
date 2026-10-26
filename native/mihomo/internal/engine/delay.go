package engine

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"sync"
	"time"

	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

const (
	delayTestTimeout   = 5 * time.Second
	delayTestBatchLife = 120 * time.Second
	delayTestWorkers   = 4
)

// Measure HTTP probes through the proxy path.
var delayExpected = utils.IntRanges[uint16]{utils.NewRange[uint16](204, 204)}

type DelayMember struct {
	Name     string `json:"name"`
	Identity string `json:"identity"`
	Type     string `json:"type"`
	Status   string `json:"status"` // pending, running, success, failed, timeout, expired, cancelled
	Delay    int    `json:"delay"`
}

type DelayBatch struct {
	ID         string        `json:"id"`
	Group      string        `json:"group"`
	State      string        `json:"state"` // running, done, cancelled, expired
	Target     string        `json:"target"`
	Members    []DelayMember `json:"members"`
	StartedAt  time.Time     `json:"startedAt"`
	FinishedAt *time.Time    `json:"finishedAt,omitempty"`
}

type delayResult struct {
	status    string
	delay     int
	proxy     C.Proxy
	providers []delayProviderStamp
}

type delayProviderStamp struct {
	provider P.ProxyProvider
	version  uint32
}

// Track public provider identity/version across nested dependencies, visiting shared
// providers and cycles once. URLTest probes each requested direct member once.
func delayProviders(proxy C.Proxy) []delayProviderStamp {
	var stamps []delayProviderStamp
	seen := make(map[P.ProxyProvider]bool)
	var visit func(C.Proxy)
	visit = func(member C.Proxy) {
		group, ok := member.Adapter().(interface{ Providers() []P.ProxyProvider })
		if !ok {
			return
		}
		for _, provider := range group.Providers() {
			if seen[provider] {
				continue
			}
			seen[provider] = true
			stamps = append(stamps, delayProviderStamp{provider, provider.Version()})
			for _, child := range provider.Proxies() {
				visit(child)
			}
		}
	}
	visit(proxy)
	return stamps
}

func delaySourceIdentity(proxy C.Proxy) string {
	hash := sha256.New()
	fmt.Fprintf(hash, "%p", proxy)
	for _, stamp := range delayProviders(proxy) {
		fmt.Fprintf(hash, "/%p:%d", stamp.provider, stamp.version)
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func delayMemberIdentity(source string, proxy C.Proxy) string {
	// Expose opaque observation identities and provider versions across the bridge.
	sum := sha256.Sum256([]byte(fmt.Sprintf("%s/%p/%s/%s", source, proxy, proxy.Name(), proxy.Type())))
	return hex.EncodeToString(sum[:])
}

func sameDelayProviders(previous, current []delayProviderStamp) bool {
	if len(previous) != len(current) {
		return false
	}
	for i, stamp := range previous {
		if stamp != current[i] || stamp.provider.Version() != stamp.version {
			return false
		}
	}
	return true
}

type delayBatch struct {
	id       string
	group    string
	identity string
	cancel   context.CancelFunc
	done     chan struct{}
	mu       sync.Mutex
	members  []DelayMember
	results  []delayResult
	state    string
	released bool
	started  time.Time
	ended    *time.Time
}

func (b *delayBatch) snapshot() DelayBatch {
	b.mu.Lock()
	defer b.mu.Unlock()
	value := DelayBatch{ID: b.id, Group: b.group, State: b.state, Target: C.DefaultTestURL,
		StartedAt: b.started, FinishedAt: b.ended, Members: make([]DelayMember, len(b.members))}
	copy(value.Members, b.members)
	for i := range value.Members {
		value.Members[i].Status = b.results[i].status
		value.Members[i].Delay = b.results[i].delay
	}
	return value
}

// set records a member result unless the batch was cancelled meanwhile.
func (b *delayBatch) set(index int, status string, delay int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	// The worker marks the member running before probing, so a settled result
	// is accepted from either pre-test state; only a cancelled batch or an
	// already-recorded result is refused.
	if b.state != "running" || (b.results[index].status != "pending" && b.results[index].status != "running") {
		return
	}
	b.results[index].status, b.results[index].delay = status, delay
}

func (b *delayBatch) finish(cancelled bool) {
	b.mu.Lock()
	if b.state == "running" {
		if cancelled {
			b.state = "cancelled"
			b.setUnfinishedLocked("cancelled")
		} else {
			b.state = "done"
		}
	}
	now := time.Now().UTC()
	b.ended = &now
	b.mu.Unlock()
	close(b.done)
}

func (b *delayBatch) setUnfinishedLocked(status string) {
	for i := range b.results {
		if b.results[i].status == "pending" || b.results[i].status == "running" {
			b.results[i].status, b.results[i].delay = status, 0
		}
	}
}

func (b *delayBatch) cancelBatch() {
	b.mu.Lock()
	if b.state == "running" {
		b.state = "cancelled"
		b.setUnfinishedLocked("cancelled")
	}
	b.mu.Unlock()
	b.cancel()
}

// Retain the probed proxy's identity with settled results until batch release.
func (b *delayBatch) checkMembers(current []C.Proxy) {
	byName := make(map[string]C.Proxy, len(current))
	for _, member := range current {
		if byName[member.Name()] == nil {
			byName[member.Name()] = member
		}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.state == "expired" || b.state == "cancelled" {
		return
	}
	for i, member := range b.members {
		actual := byName[member.Name]
		if actual != b.results[i].proxy || !sameDelayProviders(b.results[i].providers, delayProviders(actual)) {
			b.state = "expired"
			for j := range b.results {
				b.results[j].status, b.results[j].delay = "expired", 0
			}
			b.cancel()
			return
		}
	}
}

// Test direct members through one bounded worker pool; poll results independently of
// slow probes.
func (e *Engine) StartDelayTest(group string, members []string) (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return "", ErrStopped
	}
	proxy := e.cfg.Proxies[group]
	if proxy == nil {
		return "", errors.New("strategy group is unavailable")
	}
	g, ok := proxy.Adapter().(interface {
		Proxies() []C.Proxy
		Name() string
	})
	if !ok {
		return "", errors.New("strategy group is unavailable")
	}
	wanted := make(map[string]bool, len(members))
	for _, name := range members {
		wanted[name] = true
	}
	targets := make([]C.Proxy, 0)
	seen := make(map[string]bool)
	for _, member := range g.Proxies() {
		if !seen[member.Name()] && (len(wanted) == 0 || wanted[member.Name()]) {
			seen[member.Name()] = true
			targets = append(targets, member)
		}
	}
	if len(wanted) > 0 && len(targets) != len(wanted) {
		return "", errors.New("strategy member is unavailable")
	}
	if len(targets) == 0 {
		return "", errors.New("strategy group has no members")
	}
	// Retain cancelled batches until all probes exit, preserving the session-wide
	// four-probe bound before new admission.
	for id, old := range e.delays {
		select {
		case <-old.done:
			delete(e.delays, id)
		default:
			return "", errors.New("a delay test is still running")
		}
	}
	e.delaySeq++
	id := time.Now().UTC().Format("20060102T150405.000000000") + "-" + strconv.Itoa(e.delaySeq)
	ctx, cancel := context.WithTimeout(context.Background(), delayTestBatchLife)
	batch := &delayBatch{id: id, group: group, identity: delaySourceIdentity(proxy), cancel: cancel, done: make(chan struct{}),
		state: "running", started: time.Now().UTC(), members: make([]DelayMember, len(targets)),
		results: make([]delayResult, len(targets))}
	for i, member := range targets {
		batch.members[i] = DelayMember{Name: member.Name(), Identity: delayMemberIdentity(batch.identity, member), Type: strategyType(member.Type()), Status: "pending"}
		batch.results[i] = delayResult{status: "pending", proxy: member, providers: delayProviders(member)}
	}
	e.delays[id] = batch
	go func() {
		defer cancel()
		runDelayBatch(ctx, batch)
		// Explicit cancellation owns release; normal terminal results remain
		// readable until the popup closes or starts another batch.
		e.mu.Lock()
		batch.mu.Lock()
		released := batch.released
		batch.mu.Unlock()
		if released && e.delays[id] == batch {
			delete(e.delays, id)
		}
		e.mu.Unlock()
	}()
	return id, nil
}

func runDelayBatch(ctx context.Context, batch *delayBatch) {
	work := make(chan int)
	var workers sync.WaitGroup
	for i := 0; i < delayTestWorkers; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for index := range work {
				batch.mu.Lock()
				cancelled := batch.state != "running"
				if !cancelled && batch.results[index].status == "pending" {
					batch.results[index].status = "running"
				}
				proxy := batch.results[index].proxy
				batch.mu.Unlock()
				if cancelled || ctx.Err() != nil {
					continue
				}
				testCtx, cancel := context.WithTimeout(ctx, delayTestTimeout)
				delay, err := proxy.URLTest(testCtx, C.DefaultTestURL, delayExpected)
				// The public unified-delay probe may return its first response with
				// nil error after its second request exceeded this member's deadline.
				testErr := testCtx.Err()
				cancel()
				switch {
				case ctx.Err() != nil:
					// Cancellation wins; discard an in-flight reply.
				case errors.Is(testErr, context.DeadlineExceeded), errors.Is(err, context.DeadlineExceeded):
					batch.set(index, "timeout", 0)
				case err == nil:
					batch.set(index, "success", int(delay))
				default:
					batch.set(index, "failed", 0)
				}
			}
		}()
	}
	go func() {
		defer close(work)
		for i := range batch.members {
			select {
			case work <- i:
			case <-ctx.Done():
				return
			}
		}
	}()
	workers.Wait()
	deadline := errors.Is(ctx.Err(), context.DeadlineExceeded)
	if deadline {
		batch.mu.Lock()
		batch.setUnfinishedLocked("timeout")
		batch.mu.Unlock()
	}
	batch.finish(ctx.Err() != nil && !deadline)
}

func (e *Engine) DelayTest(id string) (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	batch := e.delays[id]
	if batch == nil || !e.available() {
		return "", errors.New("delay test is unavailable")
	}
	var members []C.Proxy
	if proxy := e.cfg.Proxies[batch.group]; proxy != nil && delaySourceIdentity(proxy) == batch.identity {
		if group, ok := proxy.Adapter().(interface{ Proxies() []C.Proxy }); ok {
			members = group.Proxies()
		}
	}
	batch.checkMembers(members)
	data, err := json.Marshal(batch.snapshot())
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func (e *Engine) CancelDelayTest(id string) {
	e.mu.Lock()
	batch := e.delays[id]
	if batch != nil {
		batch.mu.Lock()
		batch.released = true
		batch.mu.Unlock()
		batch.cancelBatch()
		select {
		case <-batch.done:
			delete(e.delays, id)
		default:
		}
	}
	e.mu.Unlock()
}

// stopDelays runs under e.mu. Cancel every batch, then join the actual probes
// before their proxies can be closed. The platform owns the UI wait deadline;
// a late native completion must still be able to confirm resource release.
func (e *Engine) stopDelays() {
	for _, batch := range e.delays {
		batch.cancelBatch()
	}
	for id, batch := range e.delays {
		<-batch.done
		delete(e.delays, id)
	}
}
