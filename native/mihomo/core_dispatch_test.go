package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"clashpseudo/native/internal/androidnet"
	A "clashpseudo/native/internal/appcontract"
	"clashpseudo/native/internal/configinput"
	"clashpseudo/native/internal/coreipc"
	"clashpseudo/native/internal/engine"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	ML "github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

func requestBytes(t *testing.T, request coreRequest, extras map[string][]byte) []byte {
	t.Helper()
	var output bytes.Buffer
	writer := coreipc.Writer{Output: &output}
	body, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	parts := map[string][]byte{A.CorePartRequest: body}
	for name, body := range extras {
		parts[name] = body
	}
	for _, name := range []string{A.CorePartRequest, A.CorePartConfig, A.CorePartOverrides, A.CorePartOptions, A.CorePartTrust} {
		body, exists := parts[name]
		if !exists {
			continue
		}
		if err = writer.JSON(A.CoreIpcFrameMetadata, map[string]any{"part": name, "bytes": len(body)}); err != nil {
			t.Fatal(err)
		}
		if err = writer.Data(body); err != nil {
			t.Fatal(err)
		}
	}
	if err = writer.JSON(A.CoreIpcFrameTerminal, map[string]bool{"complete": true}); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}
func validRequest(operation int, id int64) coreRequest {
	return coreRequest{Protocol: 1, Operation: operation, ProcessID: "process", RequestID: id, Arguments: json.RawMessage(`{}`)}
}
func invokeBytes(t *testing.T, d *coreDispatcher, operation int, id int64, body []byte, callback ...nativeCallbacks) ([]coreipc.Frame, map[string]json.RawMessage) {
	t.Helper()
	input, send, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	receive, output, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer receive.Close()
	sent := make(chan error, 1)
	go func() { _, err := send.Write(body); sent <- errors.Join(err, send.Close()) }()
	result := make(chan []byte, 1)
	var callbacks nativeCallbacks
	if len(callback) > 0 {
		callbacks = callback[0]
	}
	go func() { result <- d.invoke(operation, id, input, output, nil, callbacks) }()
	frames := []coreipc.Frame{}
	for {
		frame, err := coreipc.ReadFrame(receive)
		if err != nil {
			if !errors.Is(err, io.EOF) {
				t.Fatal(err)
			}
			break
		}
		frames = append(frames, frame)
	}
	ackBytes := <-result
	var ack map[string]json.RawMessage
	if err = json.Unmarshal(ackBytes, &ack); err != nil {
		t.Fatal(err)
	}
	if err = <-sent; err != nil {
		t.Fatal(err)
	}
	if _, err = input.Stat(); !errors.Is(err, os.ErrClosed) {
		t.Fatal("Go未关闭input FD", err)
	}
	if _, err = output.Stat(); !errors.Is(err, os.ErrClosed) {
		t.Fatal("Go未关闭output FD", err)
	}
	return frames, ack
}
func terminalFrom(t *testing.T, frames []coreipc.Frame) coreipc.Terminal {
	t.Helper()
	if len(frames) == 0 || frames[len(frames)-1].Kind != A.CoreIpcFrameTerminal {
		t.Fatal("结果缺少terminal")
	}
	var terminal coreipc.Terminal
	if err := json.Unmarshal(frames[len(frames)-1].Payload, &terminal); err != nil {
		t.Fatal(err)
	}
	return terminal
}
func TestDispatcherVersionReturnsOneTerminalAndOwnsFDs(t *testing.T) {
	d := &coreDispatcher{}
	request := validRequest(A.CoreOperationVersion, 1)
	frames, ack := invokeBytes(t, d, request.Operation, request.RequestID, requestBytes(t, request, nil))
	terminal := terminalFrom(t, frames)
	if len(frames) != 2 || frames[0].Kind != A.CoreIpcFrameData || !terminal.Complete || !terminal.Exited || terminal.Error != nil || string(ack["accepted"]) != "true" || len(d.calls) != 0 {
		t.Fatal("统一结果或active生命周期错误", terminal, ack)
	}
}
func TestDispatcherRejectsOnlyActiveDuplicateAndAllowsOutOfOrderAndSerialSteps(t *testing.T) {
	d := &coreDispatcher{}
	_, first, err := d.accept(A.CoreOperationVersion, 10, nil)
	if err != nil {
		t.Fatal(err)
	}
	_, second, err := d.accept(A.CoreOperationPaths, 2, nil)
	if err != nil {
		t.Fatal("乱序到达被拒绝", err)
	}
	if _, _, err = d.accept(A.CoreOperationVersion, 10, nil); err == nil {
		t.Fatal("重复active ID被受理")
	}
	d.mu.Lock()
	delete(d.calls, 10)
	delete(d.calls, 2)
	d.mu.Unlock()
	first.cancel()
	second.cancel()
	_, third, err := d.accept(A.CoreOperationPaths, 10, nil)
	if err != nil {
		t.Fatal("串行native步骤不能沿用logical ID", err)
	}
	third.cancel()
}
func TestDispatcherContextIdentityChecksAlsoCoverCancelAndStop(t *testing.T) {
	for _, operation := range []int{A.CoreOperationNodes, A.CoreOperationResourceUpdate, A.CoreOperationCancel, A.CoreOperationStop, A.CoreOperationShutdown} {
		d := &coreDispatcher{}
		prepare := validRequest(A.CoreOperationPrepare, 1)
		prepare.InputID = "loaded"
		prepare.Generation = 3
		prepare.NetworkRevision = 4
		if err := d.identity(prepare, prepare.Operation, prepare.RequestID); err != nil {
			t.Fatal(err)
		}
		current := validRequest(operation, 2)
		current.InputID = "old"
		current.Generation = 3
		current.NetworkRevision = 4
		if err := d.identity(current, operation, 2); err == nil {
			t.Fatalf("旧inputId作用于operation=%d", operation)
		}
		current.InputID = "loaded"
		if err := d.identity(current, operation, 2); err != nil {
			t.Fatal(err)
		}
		current.ProcessID = "old-process"
		if err := d.identity(current, operation, 2); err == nil {
			t.Fatal("旧processId未被拒绝")
		}
	}
}
func TestDispatcherPlatformErrorPreservesTypedCauseAndJoinedOriginalErrors(t *testing.T) {
	processTrust.Lock()
	initialized := processTrust.initialized
	processTrust.initialized = true
	processTrust.Unlock()
	defer func() {
		processTrust.Lock()
		processTrust.initialized = initialized
		processTrust.Unlock()
	}()
	const body = "tun: {enable: false}\nrules: ['MATCH,DIRECT']\n"
	raw, presence, err := configinput.Decode([]byte(body), "rule", "", true)
	if err != nil {
		t.Fatal(err)
	}
	original := androidnet.PlatformRuntime(raw, presence)
	if original == nil {
		t.Fatal("公开平台检查未产生实际能力错误")
	}
	for _, joined := range []bool{false, true} {
		t.Run(map[bool]string{false: "platform", true: "joined"}[joined], func(t *testing.T) {
			d := &coreDispatcher{}
			defer func() {
				if err := d.engine.Stop(); err != nil {
					t.Error(err)
				}
			}()
			request := validRequest(A.CoreOperationPrepare, 1)
			request.InputID = "platform-error"
			request.Arguments, _ = json.Marshal(map[string]any{"home": t.TempDir()})
			callbacks := nativeCallbacks{Protect: func(int) error { return nil }, ProtectNetwork: func(int, string) error { return nil }}
			purpose := "RUNNING"
			configuration := body
			if joined {
				purpose, configuration = "PREVIEW", "rules: ['MATCH,DIRECT']\n"
				callbacks.Seed = func([]engine.GeoSeed) error { return errors.Join(original, errors.New("original cleanup failure")) }
			}
			options, _ := json.Marshal(map[string]any{"purpose": purpose, "vpnIntent": !joined, "generation": 1, "composition": "fixture"})
			request.Generation = 1
			frames, ack := invokeBytes(t, d, request.Operation, 1, requestBytes(t, request, map[string][]byte{
				A.CorePartConfig: []byte(configuration), A.CorePartOverrides: []byte("[]"), A.CorePartOptions: options,
			}), callbacks)
			terminal := terminalFrom(t, frames)
			if terminal.Complete || terminal.Error == nil || terminal.Error.Code != A.CoreErrorCallFailed || !terminal.Exited || string(ack["exited"]) != "true" {
				t.Fatal("实际能力错误未进入terminal/ack", terminal, ack)
			}
			for _, encoded := range [][]byte{frames[len(frames)-1].Payload, ack["error"]} {
				var envelope any
				if err := json.Unmarshal(encoded, &envelope); err != nil {
					t.Fatal(err)
				}
				text := string(encoded)
				for _, want := range []string{`"id":"nativeConfigurationUnsupported"`, `"field":"tun.enable"`, `"id":"nativeReasonTunDisabled"`, `"detail":"tun.enable: tunDisabled"`, `tun.enable: tunDisabled`} {
					if !strings.Contains(text, want) {
						t.Fatalf("typed cause或原message缺失 %s: %s", want, text)
					}
				}
				if joined && !strings.Contains(text, "original cleanup failure") {
					t.Fatal("Join丢失原cleanup错误", text)
				}
			}
		})
	}
	if plain := coreipc.Failure(A.CoreErrorCallFailed, errors.New("tun.enable: tunDisabled")); plain.Cause != nil {
		t.Fatal("按任意错误文字伪造了typed descriptor", plain)
	}
}

func TestDispatcherProtocolUTF8IdentityAndEOFKeepActualFailures(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*coreRequest)
		code   string
	}{
		{"protocol", func(r *coreRequest) { r.Protocol = 2 }, A.CoreErrorProtocolMismatch},
		{"requestId", func(r *coreRequest) { r.RequestID = 2 }, A.CoreErrorIdentityMismatch},
		{"operation", func(r *coreRequest) { r.Operation = A.CoreOperationPaths }, A.CoreErrorIdentityMismatch},
		{"generation", func(r *coreRequest) { r.Generation = -1 }, A.CoreErrorIdentityMismatch},
		{"utf8-bytes", func(r *coreRequest) { r.ProcessID = strings.Repeat("界", 86) }, A.CoreErrorIdentityMismatch},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := &coreDispatcher{}
			request := validRequest(A.CoreOperationVersion, 1)
			tc.change(&request)
			frames, _ := invokeBytes(t, d, A.CoreOperationVersion, 1, requestBytes(t, request, nil))
			terminal := terminalFrom(t, frames)
			if terminal.Error == nil || terminal.Error.Code != tc.code || terminal.Complete || !terminal.Exited {
				t.Fatal(terminal)
			}
		})
	}
	request := validRequest(A.CoreOperationVersion, 1)
	body := requestBytes(t, request, nil)
	body = body[:len(body)-5-len(`{"complete":true}`)]
	frames, _ := invokeBytes(t, &coreDispatcher{}, request.Operation, 1, body)
	terminal := terminalFrom(t, frames)
	if terminal.Error == nil || terminal.Error.Code != A.CoreErrorTransportInterrupted || !strings.Contains(terminal.Error.Message, "EOF") {
		t.Fatal("EOF被当成成功", terminal)
	}
}
func TestDispatcherOrdinaryDataHasNoAggregateEightMiBLimit(t *testing.T) {
	request := validRequest(A.CoreOperationCompose, 1)
	text := bytes.Repeat([]byte("#"), 9<<20)
	frames, _ := invokeBytes(t, &coreDispatcher{}, request.Operation, 1, requestBytes(t, request, map[string][]byte{A.CorePartConfig: text, A.CorePartOverrides: []byte("[]")}))
	terminal := terminalFrom(t, frames)
	var data []byte
	for _, frame := range frames {
		if frame.Kind == A.CoreIpcFrameData {
			data = append(data, frame.Payload...)
		}
	}
	var result struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatal(err)
	}
	if !terminal.Complete || result.Text != string(text) || len(frames) < 3 {
		t.Fatal("普通data仍受8MiB总量限制", terminal)
	}
}
func TestDispatcherLogsPublishMetadataBeforePrepareAndCancelBackpressure(t *testing.T) {
	d := &coreDispatcher{}
	input, send, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	receive, output, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer receive.Close()
	request := validRequest(A.CoreOperationLogs, 1)
	request.InputID = "loading"
	sent := make(chan error, 1)
	go func() { _, err := send.Write(requestBytes(t, request, nil)); sent <- errors.Join(err, send.Close()) }()
	result := make(chan []byte, 1)
	go func() { result <- d.invoke(request.Operation, 1, input, output, nil, nativeCallbacks{}) }()
	frame, err := coreipc.ReadFrame(receive)
	if err != nil || frame.Kind != A.CoreIpcFrameMetadata {
		t.Fatal("PREPARE前未立即发布logs metadata", frame, err)
	}
	ML.SetLevel(ML.INFO)
	ML.Infoln("%s", strings.Repeat("x", 1<<20))
	var header [5]byte
	if _, err = io.ReadFull(receive, header[:]); err != nil || header[4] != A.CoreIpcFrameRecord || binary.BigEndian.Uint32(header[:4]) < 1<<20 {
		t.Fatal("未进入大record传输", err)
	}
	watermark := validRequest(A.CoreOperationLogs, 2)
	watermark.InputID = request.InputID
	watermark.Arguments = json.RawMessage(`{"watermark":true}`)
	concurrent := make(chan struct{}, 1)
	go func() {
		defer func() { concurrent <- struct{}{} }()
		frames, ack := invokeBytes(t, d, watermark.Operation, watermark.RequestID, requestBytes(t, watermark, nil))
		terminal := terminalFrom(t, frames)
		var value struct {
			Source string `json:"source"`
			Next   int64  `json:"next"`
		}
		if len(frames) != 2 || frames[0].Kind != A.CoreIpcFrameData || json.Unmarshal(frames[0].Payload, &value) != nil || value.Next < 1 || value.Source != "process/loading" || !terminal.Complete || terminal.Source != value.Source || string(ack["exited"]) != "true" {
			t.Error("backpressure期间watermark结果错误", frames, terminal, ack)
		}
	}()
	select {
	case <-concurrent:
	case <-time.After(time.Second):
		t.Fatal("watermark等待了stream backpressure")
	}
	second := validRequest(A.CoreOperationLogs, 3)
	second.InputID = request.InputID
	frames, ack := invokeBytes(t, d, second.Operation, second.RequestID, requestBytes(t, second, nil))
	terminal := terminalFrom(t, frames)
	if terminal.Complete || terminal.Error == nil || !strings.Contains(terminal.Error.Message, "log transfer is already active") || string(ack["exited"]) != "true" {
		t.Fatal("第二个默认consumer未被拒绝", terminal, ack)
	}
	if err = d.cancel(1); err != nil {
		t.Fatal(err)
	}
	select {
	case ack := <-result:
		if !bytes.Contains(ack, []byte(`"exited":true`)) {
			t.Fatal(string(ack))
		}
	case <-time.After(time.Second):
		t.Fatal("取消未解除FD backpressure")
	}
	if err = <-sent; err != nil {
		t.Fatal(err)
	}
	if err = d.engine.Stop(); err != nil {
		t.Fatal(err)
	}
	if len(d.calls) != 0 {
		t.Fatal("已经退出的logs调用仍在active集合")
	}
}
func TestDispatcherLogWatermarkDoesNotConsumeOrResetSequence(t *testing.T) {
	d := &coreDispatcher{}
	queue := d.engine.LogQueue()
	defer func() {
		if err := d.engine.Stop(); err != nil {
			t.Error(err)
		}
	}()
	ML.SetLevel(ML.INFO)
	ML.Infoln("watermark-before")
	waitSequence := func(after int64) {
		t.Helper()
		deadline := time.Now().Add(time.Second)
		for {
			next, _ := queue.Watermark()
			if next > after {
				return
			}
			if time.Now().After(deadline) {
				t.Fatal("日志未到达传输queue")
			}
			time.Sleep(time.Millisecond)
		}
	}
	waitSequence(0)
	request := validRequest(A.CoreOperationLogs, 1)
	request.InputID = "input"
	request.Arguments = json.RawMessage(`{"watermark":true}`)
	frames, _ := invokeBytes(t, d, request.Operation, request.RequestID, requestBytes(t, request, nil))
	terminal := terminalFrom(t, frames)
	var watermark struct {
		Source  string `json:"source"`
		Next    int64  `json:"next"`
		Dropped int64  `json:"dropped"`
	}
	if len(frames) != 2 || frames[0].Kind != A.CoreIpcFrameData || json.Unmarshal(frames[0].Payload, &watermark) != nil || watermark.Source != "process/input" || terminal.Source != watermark.Source || !terminal.Complete {
		t.Fatal("watermark结果错误", frames, terminal)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	first, err := queue.Next(ctx)
	if err != nil || first.Text != "watermark-before" || first.Seq != watermark.Next {
		t.Fatal("watermark消费了已有记录或返回下一条序号", first, watermark, err)
	}
	ML.Infoln("watermark-after")
	waitSequence(watermark.Next)
	second, err := queue.Next(ctx)
	if err != nil || second.Seq <= watermark.Next || second.Text != "watermark-after" {
		t.Fatal("后续Seq没有越过watermark", second, err)
	}
	next, dropped := queue.Watermark()
	if next != second.Seq || dropped != watermark.Dropped || d.logConsumer {
		t.Fatal("watermark重置了计数或占用了consumer", next, dropped, watermark)
	}
}

func TestPlatformCallbackCauseAndSuppressedRemainStructured(t *testing.T) {
	body := []byte(`{"wire":"AQI=","exited":true,"error":{"message":"original","cause":{"message":"cause"},"suppressed":[{"message":"close"}]}}`)
	var value struct {
		Wire   string `json:"wire"`
		Exited bool   `json:"exited"`
	}
	err := decodeCallback(body, &value)
	failure := coreipc.Failure("callFailed", err)
	encoded, encodeErr := json.Marshal(failure)
	if encodeErr != nil || value.Wire != "AQI=" || !value.Exited || !bytes.Contains(encoded, []byte(`"suppressed"`)) || !bytes.Contains(encoded, []byte(`"cause"`)) {
		t.Fatal("callback值或原始cause结构丢失", string(encoded), encodeErr)
	}
}
func TestPlatformQueryCancellationWaitsForRealCallbackAndDoesNotRunAfterExit(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	entered, release := make(chan struct{}), make(chan struct{})
	original := errors.New("CancellationSignal original cause")
	var calls atomic.Int64
	done := make(chan struct{})
	var body []byte
	var err error
	go func() {
		body, err = invokePlatformQuery(ctx, func() []byte { close(entered); <-release; return []byte("actual") }, func() error { calls.Add(1); return original })
		close(done)
	}()
	<-entered
	cancel()
	select {
	case <-done:
		t.Fatal("原同步callback退出前完成")
	case <-time.After(30 * time.Millisecond):
	}
	close(release)
	<-done
	if string(body) != "actual" || !errors.Is(err, original) || calls.Load() != 1 || callbackCancellation(err) != original {
		t.Fatal("实际结果或取消cause丢失", string(body), err)
	}
	for i := 0; i < 100; i++ {
		ctx, cancel := context.WithCancel(context.Background())
		body, err = invokePlatformQuery(ctx, func() []byte { return []byte("done") }, func() error { t.Error("完成后补发取消"); return nil })
		cancel()
		if err != nil || string(body) != "done" {
			t.Fatal(err)
		}
	}
}

func TestDispatcherStrategyRestoreDoesNotWriteSelectedCache(t *testing.T) {
	if os.Getenv("PSEUDO_DISPATCH_STRATEGY_TEST") != "1" {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestDispatcherStrategyRestoreDoesNotWriteSelectedCache$", "-test.count=1")
		if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
			command.Args = append(command.Args, "-test.gocoverdir="+directory.Value.String())
		}
		command.Env = append(os.Environ(), "PSEUDO_DISPATCH_STRATEGY_TEST=1")
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("独立strategy dispatcher测试失败: %v\n%s", err, output)
		}
		return
	}
	processTrust.Lock()
	processTrust.initialized = true
	processTrust.Unlock()
	d := &coreDispatcher{}
	defer func() {
		if err := d.engine.Stop(); err != nil {
			t.Error(err)
		}
	}()
	prepare := validRequest(A.CoreOperationPrepare, 1)
	prepare.InputID, prepare.Generation, prepare.NetworkRevision = "strategy-profile", 7, 3
	prepare.Arguments, _ = json.Marshal(map[string]any{"home": t.TempDir()})
	options := []byte(`{"purpose":"PREVIEW","generation":7,"composition":"strategy-profile","network":{"revision":3}}`)
	body := []byte("profile: {store-selected: true}\nproxy-groups:\n - {name: pick, type: select, proxies: [DIRECT, REJECT]}\nrules: ['MATCH,DIRECT']\n")
	frames, _ := invokeBytes(t, d, prepare.Operation, prepare.RequestID, requestBytes(t, prepare, map[string][]byte{A.CorePartConfig: body, A.CorePartOverrides: []byte("[]"), A.CorePartOptions: options}), nativeCallbacks{Protect: func(int) error { return nil }})
	if terminal := terminalFrom(t, frames); !terminal.Complete || terminal.Error != nil {
		t.Fatal("profile装载失败", terminal)
	}
	for index, tc := range []struct {
		member  string
		restore bool
	}{{"REJECT", true}, {"DIRECT", false}} {
		request := validRequest(A.CoreOperationStrategySelect, int64(index+2))
		request.InputID, request.Generation, request.NetworkRevision = prepare.InputID, prepare.Generation, prepare.NetworkRevision
		request.Arguments, _ = json.Marshal(map[string]any{"group": "pick", "choice": map[string]any{"type": "select", "member": tc.member}, "restore": tc.restore})
		frames, _ := invokeBytes(t, d, request.Operation, request.RequestID, requestBytes(t, request, nil))
		if terminal := terminalFrom(t, frames); !terminal.Complete || terminal.Error != nil {
			t.Fatal("strategySelect失败", terminal)
		}
		selector := tunnel.Proxies()["pick"].Adapter().(*outboundgroup.Selector)
		if selector.Now() != tc.member {
			t.Fatal("dispatcher未应用真实选择", selector.Now(), tc.member)
		}
		selected := cachefile.Cache().SelectedMap()
		if tc.restore && selected["pick"] != "" {
			t.Fatal("restore写入了上游selected cache", selected)
		}
		if !tc.restore && selected["pick"] != tc.member {
			t.Fatal("显式操作没有写入上游selected cache", selected)
		}
	}
}
