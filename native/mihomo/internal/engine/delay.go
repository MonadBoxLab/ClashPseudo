package engine

import (
	"context"
	"errors"
	"time"

	"clashpseudo/native/internal/coreview"
	G "github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"
)

var delayExpected = utils.IntRanges[uint16]{utils.NewRange[uint16](204, 204)}

const delayTestTimeout = 5 * time.Second

func delaySourceIdentity(proxy C.Proxy) string { return coreview.GroupSourceIdentity(proxy) }
func delayMemberIdentity(source string, proxy C.Proxy) string {
	return coreview.MemberIdentity(source, proxy)
}

// URLTest只执行一个代理的一次公开测试；取消后仍等待公开调用实际返回。
func (e *Engine) URLTest(ctx context.Context, groupName, name, identity, url string, timeout time.Duration) (uint16, error) {
	e.mu.Lock()
	if !e.available() {
		e.mu.Unlock()
		return 0, ErrStopped
	}
	groupProxy := e.cfg.Proxies[groupName]
	if groupProxy == nil {
		e.mu.Unlock()
		return 0, errors.New("proxy group is unavailable")
	}
	group, ok := groupProxy.Adapter().(G.ProxyGroup)
	if !ok {
		e.mu.Unlock()
		return 0, errors.New("proxy group is unavailable")
	}
	source := coreview.GroupSourceIdentity(groupProxy)
	var proxy C.Proxy
	for _, member := range group.Proxies() {
		if member.Name() == name && coreview.MemberIdentity(source, member) == identity {
			proxy = member
			break
		}
	}
	if proxy == nil {
		e.mu.Unlock()
		return 0, coreview.ErrNodesChanged
	}
	owner := e.owner
	e.updates.Add(1)
	e.mu.Unlock()
	defer e.updates.Done()
	if url == "" {
		url = C.DefaultTestURL
	}
	if timeout <= 0 {
		timeout = delayTestTimeout
	}
	child, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	stop := context.AfterFunc(owner.ctx, cancel)
	defer stop()
	return proxy.URLTest(child, url, delayExpected)
}
