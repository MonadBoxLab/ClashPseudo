package ingress

import (
	"errors"
	"os"
	"strings"
	"syscall"
	"testing"

	"clashpseudo/native/internal/configinput"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/tunnel"
)

func parsedTunOptions(t *testing.T, body string) LC.Tun {
	t.Helper()
	raw, _, err := configinput.Decode([]byte(body), "rule", "", true)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		for _, proxy := range cfg.Proxies {
			if err := proxy.Close(); err != nil {
				t.Error(err)
			}
		}
	})
	return cfg.General.Tun
}
func descriptorClosed(t *testing.T, fd int) {
	t.Helper()
	var stat syscall.Stat_t
	if err := syscall.Fstat(fd, &stat); !errors.Is(err, syscall.EBADF) {
		t.Fatalf("FD %d未关闭：%v", fd, err)
	}
}
func TestExternalDescriptorHandoffsDoNotCloseReusedNumber(t *testing.T) {
	for _, closedByPublic := range []bool{false, true} {
		options := parsedTunOptions(t, "ipv6: false\nrules: ['MATCH,DIRECT']\n")
		fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
		if err != nil {
			t.Fatal(err)
		}
		replacement := -1
		original := errors.New("public constructor original cause")
		value, err, uncertain := newTun(fd, options, tunnel.Tunnel, func(got LC.Tun, _ C.Tunnel) (*Tun, error) {
			if got.FileDescriptor != fd || got.AutoRoute || got.AutoDetectInterface || !sing_tun.EnforceBindInterface {
				t.Fatal("external FD平台参数改变")
			}
			if closedByPublic {
				if err := syscall.Close(fd); err != nil {
					t.Fatal(err)
				}
				replacement, err = syscall.Open("/dev/null", syscall.O_RDWR, 0)
				if err != nil || replacement != fd {
					t.Fatal("测试未复用原FD", replacement, err)
				}
			}
			return nil, original
		})
		if value != nil || err != original || !uncertain {
			t.Fatal("构造错误或未确认的FD归属改变", value, err, uncertain)
		}
		var stat syscall.Stat_t
		if err := syscall.Fstat(fd, &stat); err != nil {
			t.Fatal("应用在公开构造失败后猜测FD归属并再次关闭", err)
		}
		if replacement >= 0 {
			_ = syscall.Close(replacement)
		} else {
			_ = syscall.Close(fd)
		}
	}
}
func TestFourExplicitStacksReachPublicConstructorWithoutFallback(t *testing.T) {
	for _, name := range []string{"mips", "gvisor", "mixed", "system"} {
		t.Run(name, func(t *testing.T) {
			options := parsedTunOptions(t, "ipv6: false\ntun: {stack: "+name+", inet6-address: []}\nrules: ['MATCH,DIRECT']\n")
			fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			defer syscall.Close(fd)
			calls := 0
			original := errors.New("selected public constructor failed")
			_, err, uncertain := newTun(fd, options, tunnel.Tunnel, func(got LC.Tun, _ C.Tunnel) (*Tun, error) {
				calls++
				if !strings.EqualFold(got.Stack.String(), name) || got.MTU != 1500 {
					t.Fatal("公开构造器未收到选中的stack或MTU")
				}
				return nil, original
			})
			if calls != 1 || err != original || !uncertain {
				t.Fatal("构造失败后重试了另一stack", calls, err)
			}
		})
	}
}
func TestTunDNSModeReachesPublicConstructor(t *testing.T) {
	for _, mode := range []string{"", "disabled", "native", "hijack"} {
		t.Run(mode, func(t *testing.T) {
			options := parsedTunOptions(t, "ipv6: false\ntun: {stack: mips, inet6-address: [], dns-mode: '"+mode+"'}\nrules: ['MATCH,DIRECT']\n")
			fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			defer syscall.Close(fd)
			checked := false
			original := errors.New("public DNS mode check")
			_, err, _ = newTun(fd, options, tunnel.Tunnel, func(got LC.Tun, _ C.Tunnel) (*Tun, error) {
				checked = true
				if got.DNSMode != mode || got.FileDescriptor != fd {
					t.Fatal("DNS mode或FD改变")
				}
				return nil, original
			})
			if !checked || err != original {
				t.Fatal("未转交公开构造器", err)
			}
		})
	}
}
func TestTunPublicConstructionAndStartErrorsKeepAllOriginalCauses(t *testing.T) {
	for _, phase := range []string{"construct", "start"} {
		options := parsedTunOptions(t, "ipv6: false\nrules: ['MATCH,DIRECT']\n")
		fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
		if err != nil {
			t.Fatal(err)
		}
		defer syscall.Close(fd)
		original := errors.New("public " + phase + " original cause")
		closeErr := errors.New("public close original cause")
		publicErr := errors.Join(original, closeErr)
		_, err, uncertain := newTun(fd, options, tunnel.Tunnel, func(LC.Tun, C.Tunnel) (*Tun, error) { return nil, publicErr })
		if err != publicErr || !errors.Is(err, original) || !errors.Is(err, closeErr) || !uncertain {
			t.Fatal("原始构造、Start或Close错误被替换", err)
		}
	}
}
func TestPublicTunExternalFDCloseAndMTUZero(t *testing.T) {
	pair, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(pair[1])
	if err = syscall.SetNonblock(pair[0], true); err != nil {
		t.Fatal(err)
	}
	options := parsedTunOptions(t, "ipv6: false\ntun: {stack: gvisor, mtu: 0}\nrules: ['MATCH,DIRECT']\n")
	value, err, uncertain := NewTun(pair[0], options, nil, tunnel.Tunnel)
	if err != nil || uncertain {
		t.Fatalf("公开external FD构造失败：%v，cleanupUncertain=%t", err, uncertain)
	}
	if value.Config().MTU != 0 {
		t.Fatal("请求MTU 0被应用改写")
	}
	if err = value.Close(); err != nil {
		t.Fatal(err)
	}
	descriptorClosed(t, pair[0])
	replacement, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(replacement)
	if err = value.Close(); !errors.Is(err, os.ErrClosed) {
		t.Fatal("重复公开Close没有保留实际上游错误", err)
	}
	var stat syscall.Stat_t
	if err = syscall.Fstat(replacement, &stat); err != nil {
		t.Fatal("重复Close关闭了复用FD", err)
	}
}
