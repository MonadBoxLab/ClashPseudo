package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"strconv"
	"sync"
	"syscall"
	"time"

	A "clashpseudo/native/internal/appcontract"
	"clashpseudo/native/internal/configinput"
	"clashpseudo/native/internal/coreipc"
	"clashpseudo/native/internal/coreview"
	"clashpseudo/native/internal/engine"
	"clashpseudo/native/internal/logstream"
)

type nativeCallbacks struct {
	Protect        func(int) error
	ProtectNetwork func(int, string) error
	DNS            func(context.Context, []byte) ([]byte, error)
	Lookup         func(context.Context, string, int) ([]netip.Addr, error)
	Seed           func([]engine.GeoSeed) error
	Changed        func(uint64, bool)
}

type coreRequest struct {
	Protocol        int             `json:"protocol"`
	Operation       int             `json:"operation"`
	ProcessID       string          `json:"processId"`
	InputID         string          `json:"inputId"`
	Generation      int64           `json:"generation"`
	RequestID       int64           `json:"requestId"`
	NetworkRevision int64           `json:"networkRevision"`
	Arguments       json.RawMessage `json:"arguments"`
}

type activeCall struct {
	cancel      context.CancelFunc
	input       *os.File
	operation   int
	cancelError error
}

type coreDispatcher struct {
	mu                          sync.Mutex
	engine                      engine.Engine
	processID, inputID          string
	generation, networkRevision int64
	calls                       map[int64]*activeCall
	logConsumer                 bool
}

var dispatcher coreDispatcher

func (d *coreDispatcher) accept(operation int, id int64, input *os.File) (context.Context, *activeCall, error) {
	if operation < A.CoreOperationPrepare || operation > A.CoreOperationVpnSpec || id <= 0 {
		return nil, nil, errors.New("invalid operation or requestId")
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.calls == nil {
		d.calls = make(map[int64]*activeCall)
	}
	if d.calls[id] != nil {
		return nil, nil, errors.New("requestId is already active")
	}
	ctx, cancel := context.WithCancel(context.Background())
	call := &activeCall{cancel: cancel, input: input, operation: operation}
	d.calls[id] = call
	return ctx, call, nil
}
func (d *coreDispatcher) identity(request coreRequest, operation int, id int64) error {
	if request.Protocol != A.CoreIpcVersion {
		return coreipc.Failure(A.CoreErrorProtocolMismatch, fmt.Errorf("protocol %d is not %d", request.Protocol, A.CoreIpcVersion))
	}
	if request.RequestID != id || request.Operation != operation || request.ProcessID == "" || len(request.ProcessID) > A.CoreIpcIdentityBytes || len(request.InputID) > A.CoreIpcIdentityBytes || request.Generation < 0 || request.NetworkRevision < 0 {
		return coreipc.Failure(A.CoreErrorIdentityMismatch, errors.New("request identity does not match JNI admission"))
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.processID == "" {
		d.processID = request.ProcessID
	}
	if d.processID != request.ProcessID {
		return coreipc.Failure(A.CoreErrorIdentityMismatch, errors.New("request belongs to another core process"))
	}
	if operation == A.CoreOperationPrepare {
		if request.InputID == "" {
			return coreipc.Failure(A.CoreErrorIdentityMismatch, errors.New("prepare inputId is missing"))
		}
		if d.inputID != "" && (d.inputID != request.InputID || d.generation != request.Generation || d.networkRevision != request.NetworkRevision) {
			return coreipc.Failure(A.CoreErrorIdentityMismatch, errors.New("a core process cannot change input identity"))
		}
		d.inputID, d.generation, d.networkRevision = request.InputID, request.Generation, request.NetworkRevision
	} else if d.inputID != "" {
		if request.InputID != d.inputID || request.Generation != d.generation || request.NetworkRevision != d.networkRevision {
			return coreipc.Failure(A.CoreErrorIdentityMismatch, errors.New("request context identity changed"))
		}
	}
	return nil
}
func (d *coreDispatcher) cancel(id int64) error {
	d.mu.Lock()
	call := d.calls[id]
	if call == nil {
		d.mu.Unlock()
		return nil
	}
	call.cancel()
	if call.input != nil {
		call.cancelError = errors.Join(call.cancelError, call.input.Close())
		call.input = nil
	}
	if call.operation == A.CoreOperationDnsQuery {
		d.engine.CancelDNSRequest(uint64(id))
	}
	if call.operation == A.CoreOperationPrepare {
		d.engine.Cancel()
	}
	err := call.cancelError
	d.mu.Unlock()
	return err
}

func validateParts(operation int, parts map[string][]byte) error {
	allowed := map[string]bool{A.CorePartRequest: true}
	required := []string{A.CorePartRequest}
	switch operation {
	case A.CoreOperationPrepare:
		required = append(required, A.CorePartConfig, A.CorePartOverrides, A.CorePartOptions)
	case A.CoreOperationCompose:
		required = append(required, A.CorePartConfig, A.CorePartOverrides)
	case A.CoreOperationInitializeTrust:
		required = append(required, A.CorePartTrust)
	}
	for _, part := range required {
		allowed[part] = true
		if _, present := parts[part]; !present {
			return fmt.Errorf("operation %d requires part %q", operation, part)
		}
	}
	for part := range parts {
		if !allowed[part] {
			return fmt.Errorf("operation %d does not accept part %q", operation, part)
		}
	}
	return nil
}

func (d *coreDispatcher) invoke(operation int, id int64, input, output, tun *os.File, callbacks nativeCallbacks) []byte {
	writer := &coreipc.Writer{Output: output}
	terminal := coreipc.Terminal{Exited: true}
	var callErr, inputCloseErr, outputCancelErr error
	var stopOutputCancellation func() bool
	var cancelledOutput chan struct{}
	ctx, call, admissionErr := d.accept(operation, id, input)
	accepted := admissionErr == nil
	if admissionErr != nil {
		callErr = admissionErr
		inputCloseErr = input.Close()
	} else {
		// 取消可打断FD上的backpressure，JNI仍等公开调用实际返回。
		cancelledOutput = make(chan struct{})
		stopOutputCancellation = context.AfterFunc(ctx, func() { outputCancelErr = output.Close(); close(cancelledOutput) })
		parts, readErr := coreipc.ReadParts(input)
		d.mu.Lock()
		if call.input != nil {
			inputCloseErr = call.input.Close()
			call.input = nil
		}
		d.mu.Unlock()
		if readErr != nil {
			callErr = readErr
		} else if ctx.Err() != nil {
			callErr = ctx.Err()
		} else {
			var request coreRequest
			if err := validateParts(operation, parts); err != nil {
				callErr = err
			} else if err := json.Unmarshal(parts[A.CorePartRequest], &request); err != nil {
				callErr = err
			} else if err = d.identity(request, operation, id); err != nil {
				callErr = err
			} else {
				if len(request.Arguments) == 0 {
					request.Arguments = []byte("{}")
				}
				var fields map[string]json.RawMessage
				if err = json.Unmarshal(request.Arguments, &fields); err != nil {
					callErr = err
				} else if fields == nil {
					callErr = errors.New("arguments must be a JSON object")
				} else {
					var transferred *os.File
					if operation == A.CoreOperationAttach {
						transferred = tun
						tun = nil
					}
					terminal.Source, callErr = d.execute(ctx, operation, id, request, parts, writer, transferred, callbacks)
				}
			}
		}
		d.mu.Lock()
		terminal.CancelError = coreipc.Failure(A.CoreErrorCallFailed, call.cancelError)
		d.mu.Unlock()
	}
	if tun != nil {
		callErr = errors.Join(callErr, tun.Close())
	}
	callErr = errors.Join(callErr, inputCloseErr)
	terminal.RecordCount = writer.Count
	terminal.Complete = callErr == nil
	terminal.Stale = errors.Is(callErr, coreview.ErrNodesChanged)
	var ruleError coreview.RuleReadError
	if errors.As(callErr, &ruleError) && string(ruleError) == "sourceChanged" {
		terminal.Stale = true
	}
	code := A.CoreErrorCallFailed
	if errors.Is(callErr, context.Canceled) {
		code = A.CoreErrorCancelled
	}
	if errors.Is(callErr, context.DeadlineExceeded) {
		code = A.CoreErrorTimedOut
	}
	terminal.Error = coreipc.Failure(code, callErr)
	if cancelCause := callbackCancellation(callErr); cancelCause != nil {
		var previous error
		if terminal.CancelError != nil {
			previous = terminal.CancelError
		}
		terminal.CancelError = coreipc.Failure(A.CoreErrorCallFailed, errors.Join(previous, cancelCause))
	}
	writeErr := writer.JSON(A.CoreIpcFrameTerminal, terminal)
	var closeErr error
	if stopOutputCancellation != nil && !stopOutputCancellation() {
		<-cancelledOutput
	} else {
		closeErr = output.Close()
	}
	if call != nil {
		d.mu.Lock()
		terminal.CancelError = coreipc.Failure(A.CoreErrorCallFailed, errors.Join(call.cancelError, outputCancelErr, callbackCancellation(callErr)))
		delete(d.calls, id)
		d.mu.Unlock()
		call.cancel()
	}
	ack, _ := json.Marshal(map[string]any{A.CoreFieldAccepted: accepted, A.CoreFieldRequestId: id, A.CoreFieldExited: true, A.CoreFieldError: coreipc.Failure(code, errors.Join(callErr, writeErr, closeErr)), "cancelError": terminal.CancelError})
	return ack
}

func (d *coreDispatcher) execute(ctx context.Context, operation int, id int64, request coreRequest, parts map[string][]byte, w *coreipc.Writer, tun *os.File, callbacks nativeCallbacks) (string, error) {
	args := request.Arguments
	data := func(value string, err error) (string, error) {
		if err != nil {
			return "", err
		}
		return "", w.Data([]byte(value))
	}
	object := func(value any) (string, error) { return "", w.JSON(A.CoreIpcFrameData, value) }
	metadata := func(value any) error { return w.JSON(A.CoreIpcFrameMetadata, value) }
	emit := func(value any) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		return w.JSON(A.CoreIpcFrameRecord, value)
	}
	switch operation {
	case A.CoreOperationPrepare:
		if !trustRootsReady() {
			return "", errors.New("Android trust roots must be initialized before preparation")
		}
		options, err := decodePreparationOptions(parts[A.CorePartOptions])
		if err != nil {
			return "", err
		}
		var meta struct {
			Home      string `json:"home"`
			Purpose   string `json:"purpose"`
			VPNIntent *bool  `json:"vpnIntent"`
			LANIntent *bool  `json:"lanIntent"`
			Mode      string `json:"mode"`
		}
		if err = json.Unmarshal(args, &meta); err != nil {
			return "", err
		}
		var optionFields map[string]json.RawMessage
		if err = json.Unmarshal(parts[A.CorePartOptions], &optionFields); err != nil {
			return "", err
		}
		conflict := func(field string) (string, error) {
			return "", coreipc.Failure(A.CoreErrorIdentityMismatch, fmt.Errorf("prepare %s differs between request and options", field))
		}
		if options.Purpose == "" {
			options.Purpose = meta.Purpose
		} else if meta.Purpose != "" && options.Purpose != meta.Purpose {
			return conflict("purpose")
		}
		if _, present := optionFields["generation"]; present && options.Generation != request.Generation {
			return conflict("generation")
		}
		options.Generation = request.Generation
		if meta.VPNIntent != nil {
			if _, present := optionFields["vpnIntent"]; present && options.VPNIntent != *meta.VPNIntent {
				return conflict("vpnIntent")
			}
			options.VPNIntent = *meta.VPNIntent
		}
		if meta.LANIntent != nil {
			if _, present := optionFields["lanIntent"]; present && options.LANIntent != *meta.LANIntent {
				return conflict("lanIntent")
			}
			options.LANIntent = *meta.LANIntent
		}
		if options.Network.Revision != request.NetworkRevision {
			return conflict("network.revision")
		}
		options.ProtectSocket, options.ProtectOutbound = callbacks.Protect, callbacks.ProtectNetwork
		options.SystemDNSQuery, options.SystemLookup = callbacks.DNS, callbacks.Lookup
		options.SeedGeo, options.SpecificationChanged = callbacks.Seed, callbacks.Changed
		var overrides []configinput.Override
		if err = json.Unmarshal(parts[A.CorePartOverrides], &overrides); err != nil {
			return "", err
		}
		if overrides == nil {
			return "", errors.New("overrides must be a JSON array")
		}
		if err = d.engine.PrepareWithOptions(meta.Home, parts[A.CorePartConfig], meta.Mode, nil, options, overrides...); err != nil {
			return "", err
		}
		return data(d.engine.PreparationResult(false))
	case A.CoreOperationAttach:
		if tun == nil {
			return "", errors.New("attach requires the Builder descriptor")
		}
		var arg struct {
			Revision uint64 `json:"revision"`
		}
		if err := json.Unmarshal(args, &arg); err != nil {
			return "", errors.Join(err, tun.Close())
		}
		runtimeFD, err := detachFile(tun)
		if err != nil {
			return "", err
		}
		if err = d.engine.Attach(runtimeFD, arg.Revision); err != nil {
			return "", err
		}
		return data(d.engine.PreparationResult(true))
	case A.CoreOperationStop, A.CoreOperationShutdown:
		err := d.engine.Stop()
		if err != nil {
			return "", err
		}
		return object(map[string]bool{"stopped": true})
	case A.CoreOperationStrategies:
		return d.engine.StreamStrategies(ctx, metadata, emit)
	case A.CoreOperationStrategySelect:
		var arg struct {
			Group   string          `json:"group"`
			Name    string          `json:"name"`
			Choice  json.RawMessage `json:"choice"`
			Restore bool            `json:"restore"`
		}
		if err := json.Unmarshal(args, &arg); err != nil {
			return "", err
		}
		if arg.Group == "" {
			arg.Group = arg.Name
		}
		choice, err := engine.DecodeChoice(arg.Choice)
		if err != nil {
			return "", err
		}
		if err = d.engine.SetStrategy(arg.Group, choice, arg.Restore); err != nil {
			return "", err
		}
		return object(map[string]bool{"applied": true})
	case A.CoreOperationRuntimeConfig:
		value, err := d.engine.RuntimeConfig()
		if err != nil {
			return "", err
		}
		return object(value)
	case A.CoreOperationNodes:
		var arg struct {
			Source *string `json:"source"`
		}
		if err := json.Unmarshal(args, &arg); err != nil {
			return "", err
		}
		return d.engine.StreamNodes(ctx, arg.Source, metadata, emit)
	case A.CoreOperationRules:
		var query coreview.RuleQuery
		if err := json.Unmarshal(args, &query); err != nil {
			return "", err
		}
		if query.Kind == "" {
			query.Kind = "main"
		}
		return d.engine.StreamRules(ctx, query, metadata, emit)
	case A.CoreOperationResources:
		return d.engine.StreamResources(ctx, metadata, emit)
	case A.CoreOperationResourceUpdate:
		var action struct {
			Action string   `json:"action"`
			Names  []string `json:"names"`
		}
		if err := json.Unmarshal(args, &action); err != nil {
			return "", err
		}
		if action.Action == "closeListeners" {
			if action.Names == nil {
				return "", errors.New("closeListeners requires names")
			}
			return object(map[string]any{"action": action.Action, "listeners": d.engine.CloseListeners(action.Names)})
		}
		if action.Action != "" {
			return "", fmt.Errorf("unknown resource action %q", action.Action)
		}
		kind, name, err := engine.DecodeResourceUpdate(args)
		if err != nil {
			return "", err
		}
		if err = d.engine.UpdateResource(kind, name); err != nil {
			return "", err
		}
		return object(map[string]string{"status": "ok"})
	case A.CoreOperationMode:
		return object(map[string]string{"mode": d.engine.Mode()})
	case A.CoreOperationModeSet:
		var arg struct {
			Mode string `json:"mode"`
		}
		if err := json.Unmarshal(args, &arg); err != nil {
			return "", err
		}
		if err := d.engine.SetMode(arg.Mode); err != nil {
			return "", err
		}
		return object(map[string]string{"mode": d.engine.Mode()})
	case A.CoreOperationConnections:
		query, err := coreview.DecodeConnectionQuery(args)
		if err != nil {
			return "", err
		}
		return data(d.engine.Connections(query))
	case A.CoreOperationConnectionClose:
		var arg struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(args, &arg); err != nil {
			return "", err
		}
		status, err := d.engine.CloseConnection(arg.ID)
		if err != nil {
			return "", err
		}
		return object(map[string]string{"status": status})
	case A.CoreOperationMemory:
		return data(ProcessMemory(), nil)
	case A.CoreOperationDnsQuery:
		var values map[string]json.RawMessage
		if err := json.Unmarshal(args, &values); err != nil {
			return "", err
		}
		values[A.CoreFieldRequestId] = json.RawMessage(strconv.FormatInt(id, 10))
		body, err := json.Marshal(values)
		if err != nil {
			return "", err
		}
		return data(d.engine.DNSQueryContext(ctx, body), nil)
	case A.CoreOperationDnsCacheClear:
		return data(d.engine.ClearDNSCache(), nil)
	case A.CoreOperationFakeIpFlush:
		return data(d.engine.FlushFakeIP(), nil)
	case A.CoreOperationLogs:
		var arg struct {
			Watermark bool `json:"watermark"`
		}
		if err := json.Unmarshal(args, &arg); err != nil {
			return "", err
		}
		source := request.ProcessID + "/" + request.InputID
		if !arg.Watermark {
			d.mu.Lock()
			if d.logConsumer {
				d.mu.Unlock()
				return source, errors.New("log transfer is already active")
			}
			d.logConsumer = true
			d.mu.Unlock()
			defer func() {
				d.mu.Lock()
				d.logConsumer = false
				d.mu.Unlock()
			}()
		}
		queue := d.engine.LogQueue()
		next, initialDropped := queue.Watermark()
		if arg.Watermark {
			return source, w.JSON(A.CoreIpcFrameData, map[string]any{"source": source, "next": next, "dropped": initialDropped})
		}
		if err := metadata(map[string]any{"source": source, "next": next, "dropped": initialDropped}); err != nil {
			return source, err
		}
		lastDropped := initialDropped
		err := d.engine.StreamLogs(ctx, func(entry logstream.LogEntry) error {
			next, dropped := queue.Watermark()
			if dropped != lastDropped {
				if err := metadata(map[string]any{"source": source, "next": next, "dropped": dropped}); err != nil {
					return err
				}
				lastDropped = dropped
			}
			return emit(entry)
		})
		if errors.Is(err, io.EOF) {
			err = nil
		}
		return source, err
	case A.CoreOperationCompose:
		var overrides []configinput.Override
		if err := json.Unmarshal(parts[A.CorePartOverrides], &overrides); err != nil {
			return "", err
		}
		var meta struct {
			MainOrigin configinput.ConfigOrigin `json:"mainOrigin"`
		}
		if err := json.Unmarshal(args, &meta); err != nil {
			return "", err
		}
		text, _, err := configinput.ComposeWithProvenance(parts[A.CorePartConfig], overrides, meta.MainOrigin)
		if err != nil {
			return "", err
		}
		return object(map[string]any{"text": string(text)})
	case A.CoreOperationVersion:
		return object(map[string]string{"version": engine.Version})
	case A.CoreOperationPaths:
		var arg struct {
			Home string `json:"home"`
		}
		if err := json.Unmarshal(args, &arg); err != nil {
			return "", err
		}
		paths, err := d.engine.Paths(arg.Home)
		if err != nil {
			return "", err
		}
		return object(paths)
	case A.CoreOperationSnapshot:
		return data(d.engine.Snapshot(), nil)
	case A.CoreOperationUrlTest:
		var arg struct {
			Name     string  `json:"name"`
			Group    *string `json:"group"`
			Identity string  `json:"identity"`
			URL      string  `json:"url"`
			Timeout  int64   `json:"timeoutMs"`
		}
		if err := json.Unmarshal(args, &arg); err != nil {
			return "", err
		}
		if arg.Timeout < 0 || arg.Timeout > 120000 {
			return "", errors.New("invalid URLTest timeout")
		}
		if arg.Group == nil || arg.Identity == "" {
			return "", errors.New("URLTest requires group and member identity")
		}
		delay, err := d.engine.URLTest(ctx, *arg.Group, arg.Name, arg.Identity, arg.URL, time.Duration(arg.Timeout)*time.Millisecond)
		_, writeErr := object(map[string]any{"name": arg.Name, "delay": delay, "identity": arg.Identity})
		return "", errors.Join(err, writeErr)
	case A.CoreOperationCancel:
		var arg struct {
			Target int64 `json:"targetRequestId"`
		}
		if err := json.Unmarshal(args, &arg); err != nil {
			return "", err
		}
		if arg.Target <= 0 || arg.Target == id {
			return "", errors.New("invalid cancellation target")
		}
		if err := d.cancel(arg.Target); err != nil && !errors.Is(err, os.ErrClosed) {
			return "", err
		}
		return object(map[string]any{"cancelled": true, "targetRequestId": arg.Target})
	case A.CoreOperationInitializeTrust:
		if err := initializeTrustRoots(parts[A.CorePartTrust]); err != nil {
			return "", err
		}
		return object(map[string]bool{"initialized": true})
	case A.CoreOperationVpnSpec:
		return data(d.engine.VPNSpec(), nil)
	}
	return "", errors.New("unknown core operation")
}

// detachFile只用于Go已经持有的TUN副本，交接后不保留os.File终结器。
func detachFile(file *os.File) (int, error) {
	fd, err := syscall.Dup(int(file.Fd()))
	closeErr := file.Close()
	if err != nil {
		return -1, errors.Join(err, closeErr)
	}
	if closeErr != nil {
		return -1, errors.Join(closeErr, syscall.Close(fd))
	}
	syscall.CloseOnExec(fd)
	return fd, nil
}
