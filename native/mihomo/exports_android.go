package main

/*
#include <stdlib.h>
int native_protect(int fd);
int native_protect_network(int fd, char* handle);
char* native_seed_geo(char* request);
int native_seed_geo_available(void);
void native_specification_changed(long long generation, char* composition, long long revision, int needed);
*/
import "C"

import (
	"encoding/json"
	"errors"
	"io"
	"unsafe"

	"clashpseudo/native/internal/engine"
	"github.com/sirupsen/logrus"

	"clashpseudo/native/internal/appcontract"
	"clashpseudo/native/internal/configinput"
)

func init() {
	// Report operation stages through Android UI and keep raw upstream log messages
	// within the bounded application log path.
	logrus.SetOutput(io.Discard)
}

var core engine.Engine

func result(err error) *C.char {
	if err == nil {
		return C.CString("")
	}
	var platform *engine.PlatformError
	if errors.As(err, &platform) {
		return C.CString(platform.Message())
	}
	return C.CString(err.Error())
}

//export CoreVersion
func CoreVersion() *C.char { return C.CString(engine.Version) }

//export CoreInitializeTrust
func CoreInitializeTrust(material *C.char, size C.int) *C.char {
	if size < 0 || size > 4<<20 {
		return result(errors.New("trust material exceeds limit"))
	}
	return result(initializeTrustRoots(C.GoBytes(unsafe.Pointer(material), size)))
}

//export CorePrepare
func CorePrepare(home, body *C.char, size C.int, mode, selections *C.char, selectionsSize C.int, fragments *C.char, fragmentsSize C.int, preparation *C.char, preparationSize C.int) *C.char {
	if !trustRootsReady() {
		return result(errors.New("Android trust roots must be initialized before preparation"))
	}
	if preparationSize <= 0 || preparationSize > maxPreparationOptions {
		return result(errors.New("invalid native preparation options"))
	}
	options, err := decodePreparationOptions(C.GoBytes(unsafe.Pointer(preparation), preparationSize))
	if err != nil {
		return result(err)
	}
	options.ProtectNetwork = func(fd int, handle string) bool {
		network := C.CString(handle)
		defer C.free(unsafe.Pointer(network))
		return C.native_protect_network(C.int(fd), network) != 0
	}
	options.SeedGeo = func(requests []engine.GeoSeed) error {
		data, err := json.Marshal(requests)
		if err != nil {
			return err
		}
		request := C.CString(string(data))
		defer C.free(unsafe.Pointer(request))
		response := C.native_seed_geo(request)
		if response == nil {
			return errors.New("bundled Geo installation callback is unavailable")
		}
		defer C.free(unsafe.Pointer(response))
		if message := C.GoString(response); message != "" {
			return errors.New(message)
		}
		return nil
	}
	if C.native_seed_geo_available() == 0 {
		if options.Purpose == "VPN" {
			return result(errors.New("Android preparation callbacks are required"))
		}
		options.SeedGeo = nil
	}
	options.SpecificationChanged = func(revision uint64, needed bool) {
		composition := C.CString(options.Composition)
		defer C.free(unsafe.Pointer(composition))
		flag := C.int(0)
		if needed {
			flag = 1
		}
		C.native_specification_changed(C.longlong(options.Generation), composition, C.longlong(revision), flag)
	}
	if size < 0 || size > configinput.MaxConfigText || fragmentsSize < 0 || fragmentsSize > appcontract.ConfigurationOverrideJsonBytes {
		return result(errors.New("configuration input exceeds limit"))
	}
	var overrides []configinput.Override
	if err := json.Unmarshal(C.GoBytes(unsafe.Pointer(fragments), fragmentsSize), &overrides); err != nil || overrides == nil {
		return result(errors.New("invalid override input"))
	}
	choices, err := engine.DecodeChoices(C.GoBytes(unsafe.Pointer(selections), selectionsSize))
	if err != nil {
		return result(err)
	}
	return result(core.PrepareWithOptions(C.GoString(home), C.GoBytes(unsafe.Pointer(body), size), C.GoString(mode), choices, func(fd int) bool {
		return C.native_protect(C.int(fd)) != 0
	}, options, overrides...))
}

//export CoreProcessMemory
func CoreProcessMemory() *C.char { return C.CString(ProcessMemory()) }

//export CoreDNSQuery
func CoreDNSQuery(value *C.char, size C.int) *C.char {
	if size <= 0 || size > engine.MaxDNSRequest {
		return C.CString(`{"error":"invalidRequest"}`)
	}
	return C.CString(core.DNSQuery(C.GoBytes(unsafe.Pointer(value), size)))
}

//export CoreCancelDNSQuery
func CoreCancelDNSQuery(sequence C.longlong) {
	if sequence > 0 {
		core.CancelDNSRequest(uint64(sequence))
	} else if sequence == 0 {
		core.CancelDNSQuery()
	}
}

//export CoreClearDNSCache
func CoreClearDNSCache() *C.char { return C.CString(core.ClearDNSCache()) }

//export CoreFlushFakeIP
func CoreFlushFakeIP() *C.char { return C.CString(core.FlushFakeIP()) }

//export CoreCanAttach
func CoreCanAttach(revision C.longlong) *C.char { return result(core.CanAttach(uint64(revision))) }

//export CoreVpnSpec
func CoreVpnSpec() *C.char { return C.CString(core.VPNSpec()) }

//export CoreUpdateNetwork
func CoreUpdateNetwork(body *C.char, size C.int) *C.char {
	if size <= 0 || size > 65536 {
		return C.CString(`{"error":"invalid network snapshot"}`)
	}
	var snapshot engine.NetworkDNS
	if json.Unmarshal(C.GoBytes(unsafe.Pointer(body), size), &snapshot) != nil {
		return C.CString(`{"error":"invalid network snapshot"}`)
	}
	return C.CString(core.UpdateNetwork(snapshot))
}

//export CoreAttach
func CoreAttach(fd C.int, revision C.longlong) *C.char {
	return result(core.Attach(int(fd), uint64(revision)))
}

//export CoreCancel
func CoreCancel() { core.Cancel() }

//export CoreStop
func CoreStop() *C.char { return result(core.Stop()) }

//export CoreMode
func CoreMode() *C.char { return C.CString(core.Mode()) }

//export CoreSetMode
func CoreSetMode(mode *C.char) *C.char { return result(core.SetMode(C.GoString(mode))) }

//export CoreStrategies
func CoreStrategies() *C.char {
	value, err := core.Strategies()
	if err != nil {
		return C.CString(`{"error":"strategy query failed"}`)
	}
	return C.CString(value)
}

//export CoreRuntimeConfig
func CoreRuntimeConfig() *C.char {
	value, err := core.RuntimeConfig()
	if err != nil {
		return C.CString(`{"error":"runtime configuration query failed"}`)
	}
	return C.CString(value)
}

//export CoreSetStrategy
func CoreSetStrategy(value *C.char, size C.int) *C.char {
	var request struct {
		Name   string          `json:"name"`
		Choice json.RawMessage `json:"choice"`
	}
	if json.Unmarshal(C.GoBytes(unsafe.Pointer(value), size), &request) != nil || request.Name == "" {
		return C.CString("invalid strategy request")
	}
	choice, err := engine.DecodeChoice(request.Choice)
	if err != nil {
		return result(err)
	}
	return result(core.SetStrategy(request.Name, choice))
}

//export CoreNodes
func CoreNodes(value *C.char, size C.int) *C.char {
	if size < 0 || size > 64<<10 {
		return C.CString(`{"error":"invalid node query"}`)
	}
	var query engine.NodeQuery
	if json.Unmarshal(C.GoBytes(unsafe.Pointer(value), size), &query) != nil {
		return C.CString(`{"error":"invalid node query"}`)
	}
	body, err := core.Nodes(query)
	if err != nil {
		return C.CString(`{"error":"node query failed; refresh the snapshot"}`)
	}
	return C.CString(body)
}

//export CoreRules
func CoreRules(value *C.char, size C.int) *C.char {
	if size < 0 || size > 64<<10 {
		return C.CString(`{"error":"invalid rule query"}`)
	}
	var query engine.RuleQuery
	if json.Unmarshal(C.GoBytes(unsafe.Pointer(value), size), &query) != nil {
		return C.CString(`{"error":"invalid rule query"}`)
	}
	body, err := core.Rules(query)
	if err != nil {
		code := "readFailed"
		var reason engine.RuleReadError
		if errors.As(err, &reason) {
			code = string(reason)
		}
		data, _ := json.Marshal(map[string]string{"error": code})
		return C.CString(string(data))
	}
	return C.CString(body)
}

//export CoreResources
func CoreResources() *C.char {
	body, err := core.Resources()
	if err != nil {
		return C.CString(`{"error":"resource query failed"}`)
	}
	return C.CString(body)
}

//export CoreUpdateResource
func CoreUpdateResource(value *C.char, size C.int) *C.char {
	if size <= 0 || size > 4<<10 {
		return C.CString(`{"error":"invalidUpdate"}`)
	}
	kind, name, err := engine.DecodeResourceUpdate(C.GoBytes(unsafe.Pointer(value), size))
	if err != nil {
		return C.CString(`{"error":"invalidUpdate"}`)
	}
	// Upstream errors can quote the source URL; only stable codes cross the bridge.
	if err := core.UpdateResource(kind, name); err != nil {
		if errors.Is(err, engine.ErrStopped) {
			return C.CString(`{"error":"stopped"}`)
		}
		return C.CString(`{"error":"updateFailed"}`)
	}
	return C.CString(`{"status":"ok"}`)
}

//export CoreLogs
func CoreLogs(value *C.char, size C.int) *C.char {
	if size < 0 || size > 4<<10 {
		return C.CString(`{"error":"invalidLogQuery"}`)
	}
	var query engine.LogQuery
	if json.Unmarshal(C.GoBytes(unsafe.Pointer(value), size), &query) != nil {
		return C.CString(`{"error":"invalidLogQuery"}`)
	}
	body, err := core.Logs(query)
	if err != nil {
		return C.CString(`{"error":"stopped"}`)
	}
	return C.CString(body)
}

//export CoreStartDelayTest
func CoreStartDelayTest(value *C.char, size C.int) *C.char {
	if size <= 0 || size > 64<<10 {
		return C.CString(`{"error":"invalidDelayRequest"}`)
	}
	var request struct {
		Group   string   `json:"group"`
		Members []string `json:"members"`
	}
	if json.Unmarshal(C.GoBytes(unsafe.Pointer(value), size), &request) != nil || request.Group == "" {
		return C.CString(`{"error":"invalidDelayRequest"}`)
	}
	id, err := core.StartDelayTest(request.Group, request.Members)
	if err != nil {
		return C.CString(`{"error":"delayUnavailable"}`)
	}
	body, _ := json.Marshal(map[string]string{"id": id})
	return C.CString(string(body))
}

//export CoreDelayTest
func CoreDelayTest(value *C.char, size C.int) *C.char {
	if size <= 0 || size > 512 {
		return C.CString(`{"error":"delayUnavailable"}`)
	}
	body, err := core.DelayTest(string(C.GoBytes(unsafe.Pointer(value), size)))
	if err != nil {
		return C.CString(`{"error":"delayUnavailable"}`)
	}
	return C.CString(body)
}

//export CoreCancelDelayTest
func CoreCancelDelayTest(value *C.char, size C.int) {
	if size > 0 && size <= 512 {
		core.CancelDelayTest(string(C.GoBytes(unsafe.Pointer(value), size)))
	}
}

//export CoreConnections
func CoreConnections(value *C.char, size C.int) *C.char {
	if size < 0 || size > engine.MaxConnectionRequest {
		return C.CString(`{"error":"invalid connection query"}`)
	}
	request, err := engine.DecodeConnectionQuery(C.GoBytes(unsafe.Pointer(value), size))
	if err != nil {
		return C.CString(`{"error":"invalid connection query"}`)
	}
	body, err := core.Connections(request)
	if err != nil {
		return C.CString(`{"error":"connection query failed"}`)
	}
	return C.CString(body)
}

//export CoreCloseConnection
func CoreCloseConnection(value *C.char, size C.int) *C.char {
	if size != 36 {
		return C.CString(`{"status":"failed"}`)
	}
	status, err := core.CloseConnection(string(C.GoBytes(unsafe.Pointer(value), size)))
	if err != nil {
		return C.CString(`{"status":"failed"}`)
	}
	body, _ := json.Marshal(map[string]string{"status": status})
	return C.CString(string(body))
}

//export CoreSnapshot
func CoreSnapshot() *C.char { return C.CString(core.Snapshot()) }
