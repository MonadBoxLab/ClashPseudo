//go:build linux && !android

package engine

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	LC "github.com/metacubex/mihomo/listener/config"
)

func prepareVPN(t *testing.T, e *Engine, body string) {
	t.Helper()
	if err := e.PrepareWithOptions(t.TempDir(), []byte(body), "rule", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 7, Composition: "test"}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { requireStop(t, e) })
}

func descriptorClosed(t *testing.T, fd int) {
	t.Helper()
	var stat syscall.Stat_t
	if err := syscall.Fstat(fd, &stat); !errors.Is(err, syscall.EBADF) {
		t.Fatalf("descriptor %d not consumed: %v", fd, err)
	}
}

func TestInvalidTunParametersConsumeDescriptor(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	prepareVPN(t, &e, validConfig)
	fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.Attach(fd, 99); err == nil {
		t.Fatal("stale specification revision accepted")
	}
	descriptorClosed(t, fd)
}

func TestZeroTunDescriptorIsRejectedAndConsumedInIsolatedProcess(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	const child = "PSEUDO_TEST_ZERO_TUN_FD"
	if os.Getenv(child) == "1" {
		if err := syscall.Close(0); err != nil && !errors.Is(err, syscall.EBADF) {
			t.Fatal(err)
		}
		fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
		if err != nil || fd != 0 {
			t.Fatalf("could not allocate descriptor zero: %d %v", fd, err)
		}
		var e Engine
		if err := e.Attach(fd, 1); err == nil {
			t.Fatal("reserved zero descriptor was accepted")
		}
		descriptorClosed(t, 0)
		return
	}
	command := exec.Command(os.Args[0], "-test.run=^TestZeroTunDescriptorIsRejectedAndConsumedInIsolatedProcess$", "-test.count=1")
	if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
		command.Args = append(command.Args, "-test.gocoverdir="+directory.Value.String())
	}
	command.Env = append(os.Environ(), child+"=1")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("isolated zero-descriptor regression failed: %v\n%s", err, output)
	}
}

func TestAttachWithoutSessionConsumesDescriptor(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	var e Engine
	if err := e.Attach(fd, 1); !errors.Is(err, ErrStopped) {
		t.Fatalf("unexpected attach result: %v", err)
	}
	descriptorClosed(t, fd)
}

// The session tests can only construct, start, and close one descriptor owner.
// Device/stack construction and their internal factories are tested in ingress.
type testTunResource struct {
	fd, replacement    int
	starts, closes     int
	onStart            func()
	startErr, closeErr error
	closed             chan struct{}
	once               sync.Once
	err                error
}

func (r *testTunResource) Start() error {
	r.starts++
	if r.onStart != nil {
		r.onStart()
	}
	return r.startErr
}

func (r *testTunResource) Close() error {
	r.once.Do(func() {
		r.closes++
		fdErr := syscall.Close(r.fd)
		var openErr error
		r.replacement, openErr = syscall.Open("/dev/null", syscall.O_RDWR, 0)
		r.err = errors.Join(fdErr, openErr, r.closeErr)
		if r.closed != nil {
			close(r.closed)
		}
	})
	return r.err
}

func testTunConstructor(resource *testTunResource) tunConstructor {
	return func(fd int, _ LC.Tun, _ []netip.AddrPort) (tunResource, error, bool) {
		resource.fd, resource.replacement = fd, -1
		if err := resource.Start(); err != nil {
			closeErr := resource.Close()
			return nil, errors.Join(err, closeErr), closeErr != nil
		}
		return resource, nil, false
	}
}

func TestAttachRegistersOnlySuccessfulPublicConstructionAndKeepsItsDescriptorOwner(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, fails := range []bool{false, true} {
		t.Run(map[bool]string{false: "success", true: "start"}[fails], func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			var e Engine
			prepareVPN(t, &e, validConfig)
			fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			resource := &testTunResource{}
			original := errors.New("original resource start failure")
			if fails {
				resource.startErr = original
			}
			resource.onStart = func() {
				if e.tun != nil {
					t.Fatal("公开构造器返回前登记了未完成的resource")
				}
			}
			if err := e.attach(fd, 1, testTunConstructor(resource)); fails {
				if !errors.Is(err, original) || e.tun != nil {
					t.Fatalf("Start failure lost its cause or resource: %v", err)
				}
			} else if err != nil {
				t.Fatal(err)
			} else {
				if !slices.Equal(e.attachedRoutes, e.spec.Routes) {
					t.Fatal("attached routes did not capture the actual specification")
				}
				requireStop(t, &e)
			}
			if resource.starts != 1 || resource.closes != 1 || resource.replacement != fd {
				t.Fatalf("resource handoff was not exact: %+v", resource)
			}
			defer syscall.Close(resource.replacement)
			var stat syscall.Stat_t
			if err := syscall.Fstat(resource.replacement, &stat); err != nil {
				t.Fatalf("raw guard closed reused descriptor: %v", err)
			}
		})
	}
}

func TestAttachConstructionFailureRetainsOriginalCauseAndCleanupState(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, uncertain := range []bool{false, true} {
		t.Run(map[bool]string{false: "confirmed", true: "uncertain"}[uncertain], func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			var e Engine
			if err := e.PrepareWithOptions(t.TempDir(), []byte(validConfig), "rule", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 7, Composition: "test"}); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				if err := e.Stop(); !uncertain && err != nil {
					t.Error(err)
				}
			})
			fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			original := errors.New("original construction failure")
			err = e.attach(fd, 1, func(fd int, _ LC.Tun, _ []netip.AddrPort) (tunResource, error, bool) {
				return nil, errors.Join(original, syscall.Close(fd)), uncertain
			})
			if !errors.Is(err, original) || e.tun != nil || e.failed != uncertain {
				t.Fatalf("construction result lost: %v failed=%t", err, e.failed)
			}
			descriptorClosed(t, fd)
		})
	}
}

func TestInvalidTunDNSModeIsRejectedBeforeNativeAllocation(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	err := e.PrepareWithOptions(t.TempDir(), []byte("tun: {dns-mode: invalid}\nrules: ['MATCH,DIRECT']\n"),
		"rule", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 7, Composition: "test"})
	if err == nil || !strings.Contains(err.Error(), "tun.dns-mode") {
		t.Fatalf("invalid DNS mode accepted: %v", err)
	}
	if e.owner != nil || e.failed || current.Load() != nil {
		t.Fatal("invalid DNS mode allocated a native session")
	}
	if retry := e.PrepareWithOptions(t.TempDir(), []byte(validConfig), "rule", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 7, Composition: "test"}); retry == nil {
		t.Fatal("同一Engine在失败后再次装载")
	}
	requireFreshEngineProcess(t, t.TempDir())
}

func TestIngressFailureDrainsAcceptedGeoWriteBeforeReleasingItsHome(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, cancelled := range []bool{false, true} {
		for _, cleanupFails := range []bool{false, true} {
			t.Run(fmt.Sprintf("cancelled=%t/cleanupFails=%t", cancelled, cleanupFails), func(t *testing.T) {
				if isolateEngineTest(t) {
					return
				}
				started, release := make(chan struct{}), make(chan struct{})
				var once sync.Once
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					close(started)
					<-release
					_, _ = w.Write(minimalGeoData)
				}))
				defer func() {
					once.Do(func() { close(release) })
					server.Close()
				}()
				occupied, err := net.Listen("tcp4", "127.0.0.1:0")
				if err != nil {
					t.Fatal(err)
				}
				defer occupied.Close()
				port := occupied.Addr().(*net.TCPAddr).Port
				var e Engine
				body := fmt.Sprintf("ipv6: false\ngeox-url: {geoip: '%s'}\nrules: ['MATCH,DIRECT']\n", server.URL)
				if err := e.PrepareWithOptions(t.TempDir(), []byte(body), "rule", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 7, Composition: "test"}); err != nil {
					t.Fatal(err)
				}
				// cleanup失败时Stop继续返回原错误。
				t.Cleanup(func() {
					once.Do(func() { close(release) })
					if err := e.Stop(); err != nil && !cleanupFails {
						t.Error(err)
					}
				})
				path, owner := e.geoPaths[0], e.owner
				updated := make(chan error, 1)
				go func() { updated <- e.UpdateResource("geo", "GeoIP") }()
				select {
				case <-started:
				case <-time.After(time.Second):
					t.Fatal("accepted Geo write did not reach its real network I/O")
				}
				fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
				if err != nil {
					t.Fatal(err)
				}
				resource := &testTunResource{fd: fd, replacement: -1, closed: make(chan struct{})}
				if cancelled {
					resource.onStart = e.Cancel
				} else {
					probe, bindErr := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", port))
					if bindErr == nil {
						_ = probe.Close()
						t.Fatal("占用端口未返回实际bind错误")
					}
					resource.startErr = bindErr
				}
				if cleanupFails {
					resource.closeErr = errors.New("original stack close failure")
				}
				attached := make(chan error, 1)
				go func() {
					attached <- e.attach(fd, 1, testTunConstructor(resource))
				}()
				select {
				case <-resource.closed:
				case <-time.After(time.Second):
					t.Fatal("ingress failure did not promptly close the attached stack")
				}
				select {
				case err := <-attached:
					t.Fatalf("Attach released its session before the accepted write returned: %v", err)
				case <-time.After(50 * time.Millisecond):
				}
				e.mu.Lock()
				retained := e.owner == owner && e.cfg != nil && e.geoPaths[0] == path && e.options.Composition == "test" && e.tun == nil
				e.mu.Unlock()
				if !retained || owner.active.Load() {
					t.Fatal("draining attachment lost its home/session or retained socket authority")
				}
				if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", func(int) bool { return true }); err == nil {
					t.Fatal("replacement session entered while the original Geo I/O was pending")
				}
				once.Do(func() { close(release) })
				select {
				case err := <-updated:
					if err != nil {
						t.Fatalf("actual completed Geo write lost its result: %v", err)
					}
				case <-time.After(time.Second):
					t.Fatal("Geo I/O did not settle after its response completed")
				}
				select {
				case err := <-attached:
					var socket *net.OpError
					if cancelled {
						if !errors.Is(err, ErrStopped) {
							t.Fatalf("late cancellation lost its original stopped cause: %v", err)
						}
					} else if !errors.As(err, &socket) || !errors.Is(err, syscall.EADDRINUSE) {
						t.Fatalf("original listener socket error was lost: %v", err)
					}
					if cleanupFails && !errors.Is(err, resource.closeErr) {
						t.Fatalf("listener failure suppressed the real stack cleanup error: %v", err)
					}
				case <-time.After(time.Second):
					t.Fatal("Attach did not finish after its real resource drain")
				}
				if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, minimalGeoData) {
					t.Fatalf("Geo write did not finish in the original home: %v", err)
				}
				if e.owner != nil || e.cfg != nil || e.geoPaths[0] != path || e.failed != cleanupFails {
					t.Fatal("settled attachment retained ownership or lost its cleanup failure state")
				}
				if resource.closes != 1 || resource.replacement != fd {
					t.Fatalf("descriptor ownership was not consumed exactly once: resource=%+v", resource)
				}
				defer syscall.Close(resource.replacement)
				var stat syscall.Stat_t
				if err := syscall.Fstat(resource.replacement, &stat); err != nil {
					t.Fatalf("attachment cleanup closed a reused descriptor number: %v", err)
				}
				if err := occupied.Close(); err != nil {
					t.Fatal(err)
				}
				probe, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", port))
				if err != nil {
					t.Fatalf("原socket错误影响了端口释放: %v", err)
				}
				if err := probe.Close(); err != nil {
					t.Fatal(err)
				}
				if !cleanupFails {
					requireFreshEngineProcess(t, t.TempDir())
				}
			})
		}
	}
}

func TestAttachStartFailureKeepsOriginalAndUnconfirmedClose(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	if err := e.PrepareWithOptions(t.TempDir(), []byte(validConfig), "rule", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 7, Composition: "test"}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = e.Stop() })
	fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	original := errors.New("original Start error")
	cleanup := errors.New("original Close error")
	resource := &testTunResource{startErr: original, closeErr: cleanup}
	err = e.attach(fd, 1, testTunConstructor(resource))
	if !errors.Is(err, original) || !errors.Is(err, cleanup) || !e.failed || e.tun != nil || resource.starts != 1 || resource.closes != 1 {
		t.Fatalf("Start/Close outcome lost: %v resource=%+v", err, resource)
	}
	defer syscall.Close(resource.replacement)
	var stat syscall.Stat_t
	if resource.replacement != fd {
		t.Fatal("test did not reuse the transferred descriptor")
	}
	if err := syscall.Fstat(resource.replacement, &stat); err != nil {
		t.Fatalf("Start failure double-closed the reused descriptor: %v", err)
	}
}
