package io.github.monadboxlab.clashpseudo.debug

import android.content.Context
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import android.util.Base64
import androidx.annotation.Keep
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.nativecore.CoreErrors
import io.github.monadboxlab.clashpseudo.nativecore.CoreFrames
import io.github.monadboxlab.clashpseudo.nativecore.CoreNativeTransport
import io.github.monadboxlab.clashpseudo.nativecore.CoreParts
import io.github.monadboxlab.clashpseudo.nativecore.CoreService
import io.github.monadboxlab.clashpseudo.nativecore.assets.BundledGeo
import io.github.monadboxlab.clashpseudo.nativecore.NativeCore
import io.github.monadboxlab.clashpseudo.nativecore.vpn.VpnSpecification
import io.github.monadboxlab.clashpseudo.trust.AppTrust
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import io.github.monadboxlab.clashpseudo.vpn.network.UnderlyingNetworks
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Run one fixed scenario at a time; all native FDs belong to the current :core process. */
internal class CoreFixtureNativeRun(
    private val context: Context,
    private val processId: String,
    private val allocate: () -> Long,
    private val io: ExecutorService,
    private val scene: Int,
    private val arguments: JSONObject,
    private val config: ByteArray?,
) {
    private val home = File(context.cacheDir, "core-fixture-${UUID.randomUUID()}")
    private val inputId = UUID.randomUUID().toString()
    private val network = UnderlyingNetworks.snapshot()
    private val callbacks = Callbacks(scene)
    private val transport = CoreNativeTransport(context, io)
    private val observations = JSONObject()
    private var prepared = false
    private var geoDirectory: File? = null
    private var geoSnapshot = 0

    fun run(): JSONObject {
        check(home.mkdir()) { "Cannot create the fixture directory" }
        observations.put("home", home.path).put("processId", processId).put("inputId", inputId)
            .put("pid", android.os.Process.myPid())
        if (scene == CoreFixtureContract.FD_REUSE) {
            descriptorReuse()
            return observations
        }
        if (scene == CoreFixtureContract.COVERAGE) {
            NativeCore.load(context)
            observations.put("coverage", writeCoverage(arguments.getString("name"), probe = true))
            return observations
        }
        observations.put("trust", call(Contract.CORE_OPERATION_INITIALIZE_TRUST,
            parts = mapOf(Contract.CORE_PART_TRUST to AppTrust.pem(context).toByteArray(Charsets.UTF_8))))
        observations.put("before", call(Contract.CORE_OPERATION_SNAPSHOT))
        try {
            when (scene) {
                CoreFixtureContract.TRUST -> observations.put("trustRepeated", call(Contract.CORE_OPERATION_INITIALIZE_TRUST,
                    parts = mapOf(Contract.CORE_PART_TRUST to AppTrust.pem(context).toByteArray(Charsets.UTF_8))))
                CoreFixtureContract.BAD_REVISION -> attachFailure(revisionOffset = 1)
                CoreFixtureContract.BAD_STACK -> attachFailure(body = DIRECT + "tun: {congestion-controller: invalid-native-test-controller}\n")
                CoreFixtureContract.SYSTEM_INTERFACE -> prepare(DIRECT + "tun: {stack: system}\n", vpn = true)
                CoreFixtureContract.MIXED_INTERFACE -> prepare(DIRECT + "tun: {stack: mixed}\n", vpn = true)
                CoreFixtureContract.REFUSE_PROTECT, CoreFixtureContract.THROW_PROTECT,
                CoreFixtureContract.ACCEPT_PROTECT -> provider()
                CoreFixtureContract.CONNECTIONS -> connections()
                CoreFixtureContract.MODES -> modes()
                CoreFixtureContract.UTF8_STRATEGIES -> strategies()
                CoreFixtureContract.FD_ZERO -> descriptorZero()
                CoreFixtureContract.GEO_MANUAL, CoreFixtureContract.GEO_AUTOMATIC,
                CoreFixtureContract.GEO_HOLD, CoreFixtureContract.GEO_PREPARE -> geo()
                CoreFixtureContract.ROUTE_PROJECTION -> routes()
                CoreFixtureContract.PREPARATION_FAILURE -> prepare(checkNotNull(config), vpn = false)
                CoreFixtureContract.GEO_CALLBACK -> geoCallback()
                CoreFixtureContract.OUTPUT_HANDOFF_FAILURE, CoreFixtureContract.TUN_HANDOFF_FAILURE -> descriptorHandoffFailure()
                else -> error("Unknown fixture scenario: $scene")
            }
        } finally {
            observations.put("callbacks", callbacks.observation())
            observations.put("shutdown", call(Contract.CORE_OPERATION_SHUTDOWN))
            observations.put("after", call(Contract.CORE_OPERATION_SNAPSHOT))
            arguments.optString("coverageName").takeIf { it.isNotEmpty() }?.let { name ->
                val suffix = "-${processId}"
                observations.put("coverage", writeCoverage(name.removeSuffix(".profraw") + suffix + ".profraw", probe = false))
            }
        }
        return observations
    }

    private fun writeCoverage(name: String, probe: Boolean): JSONObject {
        require(name.length <= 240 && Regex("validation-native-[a-zA-Z0-9-]+\\.profraw").matches(name))
        val file = File(context.filesDir, name)
        check(!file.exists()) { "Coverage file already exists" }
        val result = JSONObject().put("newFile", true).put("processId", processId)
        if (probe) {
            val values = JSONArray()
            for (first in listOf(false, true)) for (second in listOf(false, true)) {
                values.put(NativeCoverage.probe(first, second))
            }
            result.put("probe", values)
        }
        return result.put("write", NativeCoverage.write(file.path)).put("path", file.path)
            .put("bytes", file.length()).put("regular", file.isFile)
    }

    private fun request(operation: Int, id: Long, arguments: JSONObject): ByteArray = JSONObject()
        .put("protocol", Contract.CORE_IPC_VERSION).put("processId", processId).put("requestId", id)
        .put("inputId", if (prepared) inputId else "").put("generation", if (prepared) 1L else 0L)
        .put("networkRevision", network.revision).put("operation", operation).put("arguments", arguments)
        .toString().toByteArray(Charsets.UTF_8)

    private fun call(operation: Int, args: JSONObject = JSONObject(),
                     parts: Map<String, ByteArray> = emptyMap(), tun: ParcelFileDescriptor? = null,
                     id: Long = allocate()): JSONObject {
        val output = ParcelFileDescriptor.createPipe()
        val reader = io.submit<JSONObject> {
            val result = JSONObject()
            val data = ByteArrayOutputStream()
            try {
                ParcelFileDescriptor.AutoCloseInputStream(output[0]).use { source ->
                    val frames = CoreFrames.Reader(source)
                    while (true) {
                        val frame = frames.read()
                        if (frame.kind == Contract.CORE_IPC_FRAME_TERMINAL) {
                            result.put("terminal", JSONObject(CoreFrames.utf8(frame.payload)))
                            break
                        }
                        check(frame.kind == Contract.CORE_IPC_FRAME_DATA)
                        check(data.size().toLong() + frame.payload.size <= Contract.CORE_IPC_FRAME_BYTES)
                        data.write(frame.payload)
                    }
                }
            } catch (error: Throwable) { result.put("transportError", CoreErrors.json(error)) }
            result.put("value", if (data.size() == 0) JSONObject() else JSONObject(CoreFrames.utf8(data.toByteArray())))
        }
        var transportError: Throwable? = null
        val receipt = try {
            output[1].use { target -> transport.stream(operation, id,
                parts + (Contract.CORE_PART_REQUEST to request(operation, id, args)), target, tun, callbacks) }
        } catch (error: io.github.monadboxlab.clashpseudo.nativecore.CoreNativeCallException) {
            transportError = error
            error.receipt
        }
        val result = reader.get(30, TimeUnit.SECONDS).put("receipt", JSONObject(CoreFrames.utf8(receipt)))
        transportError?.let { result.put("transportError", CoreErrors.json(it)) }
        return result
    }

    private fun prepare(body: ByteArray, vpn: Boolean): JSONObject {
        check(!prepared) { "Each fixture process prepares only one context" }
        prepared = true
        val purpose = if (vpn) Contract.CORE_PURPOSE_RUNNING else Contract.CORE_PURPOSE_PREVIEW
        val options = JSONObject().put("purpose", purpose).put("generation", 1)
            .put("composition", "native-fixture-$scene").put("network", network.json())
            .put("vpnIntent", vpn).put("lanIntent", false)
        val result = call(Contract.CORE_OPERATION_PREPARE,
            JSONObject().put("home", home.path).put("mode", "rule").put("purpose", purpose)
                .put("vpnIntent", vpn).put("lanIntent", false),
            mapOf(Contract.CORE_PART_CONFIG to body, Contract.CORE_PART_OVERRIDES to "[]".toByteArray(),
                Contract.CORE_PART_OPTIONS to options.toString().toByteArray(Charsets.UTF_8)))
        observations.put("prepare", result)
        return result
    }

    private fun prepare(body: String = DIRECT, vpn: Boolean = false): JSONObject = prepare(body.toByteArray(Charsets.UTF_8), vpn)
    private fun value(result: JSONObject) = result.getJSONObject("value")

    private fun attachFailure(body: String = DIRECT, revisionOffset: Long = 0) {
        prepare(body, vpn = true)
        val specification = call(Contract.CORE_OPERATION_VPN_SPEC)
        observations.put("specification", specification)
        val revision = value(specification).getLong("revision")
        val marker = File(home, "descriptor-marker").apply { writeBytes(byteArrayOf()) }
        val original = Os.stat(marker.path)
        ParcelFileDescriptor.open(marker, ParcelFileDescriptor.MODE_READ_WRITE).use { retained ->
            val transferred = ParcelFileDescriptor.dup(retained.fileDescriptor)
            val transferredFd = transferred.fd
            observations.put("attach", invokeAttach(transferred, revision + revisionOffset))
            observations.put("retainedFd", retained.fd).put("retainedInode", Os.fstat(retained.fileDescriptor).st_ino)
                .put("originalInode", original.st_ino).put("transferredConsumed", !owns(transferredFd, original))
                .put("matchingDescriptorsAfterAttach", matchingDescriptors(marker, original))
        }
        observations.put("matchingDescriptorsAfterRetainedClose", matchingDescriptors(marker, original))
            .put("attachedState", call(Contract.CORE_OPERATION_SNAPSHOT))
    }

    /** Observe the independent copy acquired by JNI directly; do not detach the original PFD. */
    private fun invokeAttach(tun: ParcelFileDescriptor, revision: Long): JSONObject {
        val id = allocate()
        val input = ParcelFileDescriptor.createPipe()
        val output = ParcelFileDescriptor.createPipe()
        val nativeInput = ParcelFileDescriptor.dup(input[0].fileDescriptor)
        val nativeOutput = ParcelFileDescriptor.dup(output[1].fileDescriptor)
        val parts = mapOf(Contract.CORE_PART_REQUEST to request(Contract.CORE_OPERATION_ATTACH, id,
            JSONObject().put("revision", revision)))
        val writer = io.submit<Unit> { ParcelFileDescriptor.AutoCloseOutputStream(input[1]).use { CoreParts.write(it, parts) } }
        val reader = io.submit<JSONObject> {
            val result = JSONObject()
            val bytes = ByteArrayOutputStream()
            try {
                ParcelFileDescriptor.AutoCloseInputStream(output[0]).use { source ->
                    val frames = CoreFrames.Reader(source)
                    while (true) {
                        val frame = frames.read()
                        if (frame.kind == Contract.CORE_IPC_FRAME_TERMINAL) {
                            result.put("terminal", JSONObject(CoreFrames.utf8(frame.payload)))
                            break
                        }
                        if (frame.kind == Contract.CORE_IPC_FRAME_DATA) bytes.write(frame.payload)
                    }
                }
                if (bytes.size() > 0) result.put("value", JSONObject(CoreFrames.utf8(bytes.toByteArray())))
            } catch (error: Throwable) { result.put("transportError", CoreErrors.json(error)) }
            result
        }
        val receipt: ByteArray
        try {
            NativeCore.load(context)
            receipt = NativeCore.invoke(Contract.CORE_OPERATION_ATTACH, id, nativeInput, nativeOutput, tun, callbacks)
            observations.put("preflightInputRetained", runCatching { Os.fstat(nativeInput.fileDescriptor); true }.getOrDefault(false))
                .put("preflightOutputRetained", runCatching { Os.fstat(nativeOutput.fileDescriptor); true }.getOrDefault(false))
                .put("tunRetainedBeforeKotlinClose", runCatching { Os.fstat(tun.fileDescriptor); true }.getOrDefault(false))
        } finally {
            nativeInput.close(); nativeOutput.close(); input[0].close(); output[1].close()
            tun.close()
        }
        val result = reader.get(10, TimeUnit.SECONDS)
        try { writer.get(10, TimeUnit.SECONDS) }
        catch (error: java.util.concurrent.ExecutionException) { result.put("writerError", CoreErrors.json(error.cause ?: error)) }
        return result.put("receipt", JSONObject(CoreFrames.utf8(receipt)))
    }

    private fun provider() {
        val port = arguments.getInt("port").also { require(it in 1..65535) }
        val token = arguments.getString("token").also { require(Regex("[a-zA-Z0-9-]{1,64}").matches(it)) }
        prepare(DIRECT + "proxy-providers:\n  fixture:\n    type: http\n    url: http://127.0.0.1:$port/$token\n" +
            "    path: ./provider.yaml\n    interval: 0\n    health-check: {enable: false}\n", vpn = true)
        observations.put("snapshot", call(Contract.CORE_OPERATION_SNAPSHOT))
        val provider = File(home, "provider.yaml")
        observations.put("providerExists", provider.isFile)
        if (provider.isFile) {
            val bytes = provider.readBytes()
            observations.put("provider", Base64.encodeToString(bytes, Base64.NO_WRAP))
                .put("matchingFiles", home.walkTopDown().filter { it.isFile }.count { it.readBytes().contentEquals(bytes) })
        }
    }

    private fun connections() {
        val query = JSONObject().put("limit", 1000).put("previousActiveIds", JSONArray())
        observations.put("unavailable", call(Contract.CORE_OPERATION_CONNECTIONS, query))
            .put("oversized", call(Contract.CORE_OPERATION_CONNECTIONS, JSONObject().put("padding", " ".repeat(65537))))
            .put("close", call(Contract.CORE_OPERATION_CONNECTION_CLOSE, JSONObject().put("id", "invalid")))
        prepare()
        observations.put("previewConnections", call(Contract.CORE_OPERATION_CONNECTIONS, query))
            .put("summary", call(Contract.CORE_OPERATION_SNAPSHOT))
    }

    private fun modes() {
        prepare()
        observations.put("initial", call(Contract.CORE_OPERATION_MODE))
        val changes = JSONArray()
        for (mode in listOf("global", "direct", "rule")) changes.put(JSONObject()
            .put("set", call(Contract.CORE_OPERATION_MODE_SET, JSONObject().put("mode", mode)))
            .put("read", call(Contract.CORE_OPERATION_MODE)))
        observations.put("changes", changes).put("invalid", call(Contract.CORE_OPERATION_MODE_SET, JSONObject().put("mode", "follow")))
            .put("afterInvalid", call(Contract.CORE_OPERATION_MODE))
        observations.put("stop", call(Contract.CORE_OPERATION_STOP)).put("stoppedMode", call(Contract.CORE_OPERATION_MODE))
            .put("stoppedSet", call(Contract.CORE_OPERATION_MODE_SET, JSONObject().put("mode", "direct")))
    }

    private fun strategies() {
        val body = DIRECT + "proxies:\n  - {name: 节点🌐, type: direct}\nproxy-groups:\n" +
            "  - {name: 出口🌐, type: select, proxies: [DIRECT, 节点🌐, REJECT]}\n"
        prepare(body)
        val sequence = JSONArray()
        for (member in listOf("节点🌐", "REJECT", "节点🌐")) {
            val selected = call(Contract.CORE_OPERATION_STRATEGY_SELECT, JSONObject().put("name", "出口🌐")
                .put("choice", JSONObject().put("type", "select").put("member", member)))
            sequence.put(JSONObject().put("select", selected).put("groups", records(Contract.CORE_OPERATION_STRATEGIES)))
        }
        observations.put("sequence", sequence).put("snapshot", call(Contract.CORE_OPERATION_SNAPSHOT))
    }

    private fun records(operation: Int): JSONObject {
        val id = allocate()
        val pipe = ParcelFileDescriptor.createPipe()
        val future = io.submit<JSONObject> {
            ParcelFileDescriptor.AutoCloseInputStream(pipe[0]).use { source ->
                val reader = CoreFrames.Reader(source)
                val records = JSONArray(); val metadata = JSONArray()
                while (true) {
                    val frame = reader.read()
                    val value = JSONObject(CoreFrames.utf8(frame.payload))
                    when (frame.kind) {
                        Contract.CORE_IPC_FRAME_RECORD -> records.put(value)
                        Contract.CORE_IPC_FRAME_METADATA -> metadata.put(value)
                        Contract.CORE_IPC_FRAME_TERMINAL -> return@submit JSONObject().put("records", records)
                            .put("metadata", metadata).put("terminal", value)
                    }
                }
                @Suppress("UNREACHABLE_CODE") JSONObject()
            }
        }
        val receipt = pipe[1].use { transport.stream(operation, id,
            mapOf(Contract.CORE_PART_REQUEST to request(operation, id, JSONObject())), it, null, callbacks) }
        return future.get(10, TimeUnit.SECONDS).put("receipt", JSONObject(CoreFrames.utf8(receipt)))
    }

    private fun descriptorReuse() {
        val originalFile = File(home, "original").apply { writeBytes(byteArrayOf()) }
        val replacementFile = File(home, "replacement").apply { writeBytes(byteArrayOf()) }
        val original = ParcelFileDescriptor.open(originalFile, ParcelFileDescriptor.MODE_READ_WRITE)
        val fd = original.fd
        val identity = Os.fstat(original.fileDescriptor)
        observations.put("liveOriginalOwned", owns(fd, identity))
        original.close()
        ParcelFileDescriptor.open(replacementFile, ParcelFileDescriptor.MODE_READ_WRITE).use { replacement ->
            observations.put("reusedNumber", replacement.fd == fd).put("differentInode", Os.fstat(replacement.fileDescriptor).st_ino != identity.st_ino)
                .put("oldOwnedAfterReuse", owns(fd, identity))
            ParcelFileDescriptor.fromFd(fd).use { Os.fstat(it.fileDescriptor) }
        }
        observations.put("oldOwnedAfterClose", owns(fd, identity))
    }

    /** JNI calls the overridden detachFd; the framework still transfers the actual FD on a successful handoff. */
    @Keep
    private class HandoffDescriptor(
        descriptor: ParcelFileDescriptor,
        val name: String,
        private val order: MutableList<String>,
        private val failure: Throwable?,
    ) : ParcelFileDescriptor(descriptor) {
        var detachCalls = 0
            private set
        var closeCalls = 0
            private set
        var transferred = false
            private set

        override fun detachFd(): Int {
            detachCalls++
            order += name
            failure?.let { throw it }
            return super.detachFd().also { transferred = true }
        }

        override fun close() {
            closeCalls++
            super.close()
        }
    }

    private fun descriptorHandoffFailure() {
        val failedName = if (scene == CoreFixtureContract.OUTPUT_HANDOFF_FAILURE) "output" else "TUN"
        val cause = IOException("$failedName detach cause 原文")
        val suppressed = IllegalStateException("$failedName detach suppressed 原文")
        val injected = IOException("$failedName detach failure 原文", cause).apply { addSuppressed(suppressed) }
        val order = mutableListOf<String>()
        val replacementFile = File(home, "handoff-replacement").apply { writeText("保留 replacement FD") }
        val tunFile = File(home, "handoff-tun").apply { writeText("Java 持有未转移的 TUN") }
        ParcelFileDescriptor.open(replacementFile, ParcelFileDescriptor.MODE_READ_WRITE).use { replacementSource ->
            val replacementIdentity = Os.fstat(replacementSource.fileDescriptor)
            val input = ParcelFileDescriptor.createPipe()
            val output = ParcelFileDescriptor.createPipe()
            val descriptors = listOf(
                HandoffDescriptor(input[0], "input", order, null),
                HandoffDescriptor(output[1], "output", order, injected.takeIf { failedName == "output" }),
                HandoffDescriptor(ParcelFileDescriptor.open(tunFile, ParcelFileDescriptor.MODE_READ_WRITE),
                    "TUN", order, injected.takeIf { failedName == "TUN" }),
            )
            val numbers = descriptors.map { it.fd }
            val identities = descriptors.map { Os.fstat(it.fileDescriptor) }
            val replacements = mutableListOf<ParcelFileDescriptor>()
            val drain = io.submit<ByteArray> {
                ParcelFileDescriptor.AutoCloseInputStream(output[0]).use { it.readBytes() }
            }
            var failure: Throwable? = null
            fun finish(action: () -> Unit) {
                try { action() } catch (error: Throwable) {
                    val original = failure
                    if (original == null) failure = error else if (original !== error) original.addSuppressed(error)
                }
            }
            try {
                val id = allocate()
                // Write the small request and close the writer before handoff; reject_handoff does not enter Go or produce frames.
                ParcelFileDescriptor.AutoCloseOutputStream(input[1]).use { target ->
                    CoreParts.write(target, mapOf(Contract.CORE_PART_REQUEST to
                        request(Contract.CORE_OPERATION_ATTACH, id, JSONObject())))
                }
                val zeroIdentity = ParcelFileDescriptor.fromFd(0).use { Os.fstat(it.fileDescriptor) }
                observations.put("unrelatedZeroPath", Os.readlink("/proc/self/fd/0"))
                    .put("unrelatedZeroBefore", owns(0, zeroIdentity))
                observations.put("handoffReceipt", JSONObject(CoreFrames.utf8(NativeCore.invoke(
                    Contract.CORE_OPERATION_ATTACH, id, descriptors[0], descriptors[1], descriptors[2], callbacks))))
                    .put("unrelatedZeroAfterNativeReturn", owns(0, zeroIdentity))
                    .put("expectedException", injected.stackTraceToString())
                    .put("detachOrder", JSONArray(order))
                val beforeClose = JSONArray()
                descriptors.forEachIndexed { index, descriptor ->
                    val state = JSONObject().put("name", descriptor.name).put("fd", numbers[index])
                        .put("detachCalls", descriptor.detachCalls).put("transferred", descriptor.transferred)
                        .put("javaCloseCalls", descriptor.closeCalls)
                        .put("originalOwned", owns(numbers[index], identities[index]))
                    if (descriptor.transferred) {
                        val errno = try {
                            ParcelFileDescriptor.fromFd(numbers[index]).use { Os.fstat(it.fileDescriptor) }
                            0
                        } catch (error: IOException) {
                            val original = generateSequence<Throwable>(error) { it.cause }
                                .filterIsInstance<ErrnoException>().firstOrNull() ?: throw error
                            if (original.errno != OsConstants.EBADF) throw error
                            original.errno
                        }
                        state.put("closedErrno", errno)
                    }
                    beforeClose.put(state)
                }
                observations.put("beforeJavaClose", beforeClose)
                for (index in descriptors.indices.filter { descriptors[it].transferred }.sortedBy { numbers[it] }) {
                    // Duplicate only into an available FD number; do not use dup2 to overwrite another owner.
                    val fd = Os.fcntlInt(replacementSource.fileDescriptor, OsConstants.F_DUPFD_CLOEXEC, numbers[index])
                    val replacement = ParcelFileDescriptor.adoptFd(fd)
                    replacements += replacement
                    check(fd == numbers[index]) { "FD number ${numbers[index]} is held by another resource; acquired $fd instead" }
                }
            } catch (error: Throwable) {
                failure = error
            } finally {
                descriptors.forEach { descriptor -> finish { descriptor.close() } }
                finish {
                    observations.put("afterJavaClose", JSONArray(descriptors.mapIndexed { index, descriptor ->
                        JSONObject().put("name", descriptor.name).put("javaCloseCalls", descriptor.closeCalls)
                            .put("originalOwned", owns(numbers[index], identities[index]))
                    }))
                    observations.put("replacementsAfterJavaClose", JSONArray(replacements.map { replacement ->
                        JSONObject().put("fd", replacement.fd).put("replacementOwned", owns(replacement.fd, replacementIdentity))
                            .put("differentResource", identities.none {
                                it.st_dev == replacementIdentity.st_dev && it.st_ino == replacementIdentity.st_ino
                            })
                    }))
                }
                finish { observations.put("outputBytesAfterDrain", drain.get(10, TimeUnit.SECONDS).size) }
                replacements.forEach { replacement -> finish { replacement.close() } }
            }
            failure?.let { throw it }
        }
        observations.put("handoffSnapshot", call(Contract.CORE_OPERATION_SNAPSHOT))
    }

    private fun descriptorZero() {
        val preparation = prepare(DIRECT, vpn = true)
        check(preparation.getJSONObject("terminal").getBoolean("complete")) { preparation.toString() }
        val projected = call(Contract.CORE_OPERATION_VPN_SPEC)
        observations.put("specification", projected)
        check(projected.getJSONObject("terminal").getBoolean("complete")) { projected.toString() }
        val specification = value(projected)
        require(Os.readlink("/proc/self/fd/0") == "/dev/null") { "FD0 does not belong to fixture stdin" }
        val marker = File(home, "owned-zero-input").apply { writeBytes(byteArrayOf()) }
        ParcelFileDescriptor.open(marker, ParcelFileDescriptor.MODE_READ_WRITE).use { original ->
            val identity = Os.fstat(original.fileDescriptor)
            require(Os.readlink("/proc/self/fd/0") == "/dev/null")
            ParcelFileDescriptor.adoptFd(0).close()
            val fd = Os.fcntlInt(original.fileDescriptor, OsConstants.F_DUPFD_CLOEXEC, 0)
            if (fd != 0) { ParcelFileDescriptor.adoptFd(fd).close(); error("FD0 was acquired by another resource") }
            val zero = ParcelFileDescriptor.adoptFd(fd)
            observations.put("zeroFd", zero.fd).put("zeroOwnedBefore", owns(0, identity))
            observations.put("attach", invokeAttach(zero, specification.getLong("revision")))
            observations.put("zeroOwnedAfterKotlinClose", owns(0, identity))
                .put("retainedOriginalInode", Os.fstat(original.fileDescriptor).st_ino).put("originalInode", identity.st_ino)
        }
        observations.put("snapshot", call(Contract.CORE_OPERATION_SNAPSHOT))
    }

    private fun geo() {
        val fixture = arguments.getJSONObject("fixture")
        val directory = GeoFixtureFiles.directory(context, fixture).also { geoDirectory = it }
        val kind = arguments.getString("kind").also { require(it in GEO_FILES) }
        for ((name, file) in GEO_FILES) {
            val target = File(home, file)
            target.writeBytes(GeoFixtureFiles.read(directory, fixture.getJSONObject("before").getString(name)))
            if (scene == CoreFixtureContract.GEO_AUTOMATIC) check(target.setLastModified(System.currentTimeMillis() - 7_200_000))
        }
        prepare(checkNotNull(config), vpn = false)
        observations.put("preparedSnapshot", call(Contract.CORE_OPERATION_SNAPSHOT))
        if (scene == CoreFixtureContract.GEO_PREPARE) return
        val query = JSONObject().put("kind", "geo").put("name", kind)
        if (scene == CoreFixtureContract.GEO_HOLD) {
            val id = allocate()
            val entered = CountDownLatch(1)
            val future = io.submit<JSONObject> { entered.countDown(); call(Contract.CORE_OPERATION_RESOURCE_UPDATE, query, id = id) }
            check(entered.await(5, TimeUnit.SECONDS))
            val end = SystemClock.elapsedRealtime() + 5000
            while (callbacks.calls.get() == 0) { check(!future.isDone && SystemClock.elapsedRealtime() < end); Thread.sleep(10) }
            observations.put("updatePendingBeforeDiagnostic", !future.isDone)
                .put("heldRuntimeConfig", call(Contract.CORE_OPERATION_RUNTIME_CONFIG))
                .put("updatePendingAfterDiagnostic", !future.isDone)
                .put("heldDiagnosticSnapshot", call(Contract.CORE_OPERATION_SNAPSHOT))
                .put("heldDiagnosticBytes", geoBytes(kind))
            observations.put("cancel", call(Contract.CORE_OPERATION_CANCEL, JSONObject().put("targetRequestId", id)))
            val stopped = io.submit<JSONObject> { call(Contract.CORE_OPERATION_SHUTDOWN) }
            val began = SystemClock.elapsedRealtime()
            val early = try { stopped.get(6200, TimeUnit.MILLISECONDS); true } catch (_: java.util.concurrent.TimeoutException) { false }
            observations.put("stopReturnedBeforeIo", early).put("updateReturnedBeforeIo", future.isDone)
                .put("holdObservedMs", SystemClock.elapsedRealtime() - began)
                .put("heldSnapshot", call(Contract.CORE_OPERATION_SNAPSHOT))
            val nextHome = File(home, "next-home").apply { check(mkdir()) }
            val nextOptions = JSONObject().put("purpose", Contract.CORE_PURPOSE_PREVIEW).put("generation", 1)
                .put("composition", "native-geo-replacement").put("network", network.json())
            observations.put("nextBeforeDrain", call(Contract.CORE_OPERATION_PREPARE,
                JSONObject().put("home", nextHome.path).put("mode", "rule").put("purpose", Contract.CORE_PURPOSE_PREVIEW)
                    .put("vpnIntent", false).put("lanIntent", false),
                mapOf(Contract.CORE_PART_CONFIG to checkNotNull(config), Contract.CORE_PART_OVERRIDES to "[]".toByteArray(),
                    Contract.CORE_PART_OPTIONS to nextOptions.toString().toByteArray())))
                .put("nextGeoExists", File(nextHome, "GeoIP.dat").exists())
            observations.put("stop", stopped.get(15, TimeUnit.SECONDS)).put("update", future.get(5, TimeUnit.SECONDS))
        } else {
            if (scene == CoreFixtureContract.GEO_AUTOMATIC) {
                val end = SystemClock.elapsedRealtime() + 10_000
                val expected = GeoFixtureFiles.read(directory, fixture.getJSONObject("after").getString(kind))
                while (!File(home, GEO_FILES.getValue(kind)).readBytes().contentEquals(expected)) {
                    check(SystemClock.elapsedRealtime() < end) { "Upstream automatic Geo update has not finished" }; Thread.sleep(10)
                }
                observations.put("automaticResources", records(Contract.CORE_OPERATION_RESOURCES))
            } else observations.put("first", call(Contract.CORE_OPERATION_RESOURCE_UPDATE, query))
            observations.put("afterFirst", geoBytes(kind)).put("second", call(Contract.CORE_OPERATION_RESOURCE_UPDATE, query))
                .put("afterSecond", geoBytes(kind)).put("directMode", call(Contract.CORE_OPERATION_MODE_SET, JSONObject().put("mode", "direct")))
                .put("direct", call(Contract.CORE_OPERATION_RESOURCE_UPDATE, query))
                .put("ruleMode", call(Contract.CORE_OPERATION_MODE_SET, JSONObject().put("mode", "rule")))
                .put("rule", call(Contract.CORE_OPERATION_RESOURCE_UPDATE, query)).put("afterRule", geoBytes(kind))
                .put("snapshot", call(Contract.CORE_OPERATION_SNAPSHOT))
        }
        observations.put("finalBytes", geoBytes(kind))
    }

    private fun geoCallback() {
        val service = checkNotNull(CoreService.instance)
        val host = service.javaClass.getDeclaredField("host").apply { isAccessible = true }.get(service)
        val callback = host.javaClass.getDeclaredMethod("callback").apply { isAccessible = true }.invoke(host)
        val seed = callback.javaClass.getDeclaredMethod("seedGeo", ByteArray::class.java).apply { isAccessible = true }
        val owner = callback as BundledGeo.Owner
        val invalid = "{原文🙂".toByteArray(Charsets.UTF_8)
        observations.put("invalidSeed", JSONObject(CoreFrames.utf8(seed.invoke(callback, invalid) as ByteArray)))
        var published = 0
        owner.publishIfCurrent { published++ }
        callback.javaClass.getDeclaredMethod("close").apply { isAccessible = true }.invoke(callback)
        var rejected: Throwable? = null
        try { owner.publishIfCurrent { published++ } } catch (error: Throwable) { rejected = error }
        observations.put("published", published).put("publicationError", rejected?.let(CoreErrors::json) ?: JSONObject.NULL)
            .put("staleSeed", JSONObject(CoreFrames.utf8(seed.invoke(callback, "[]".toByteArray()) as ByteArray)))
    }

    private fun geoBytes(kind: String) = GeoFixtureFiles.snapshot(checkNotNull(geoDirectory),
        File(home, GEO_FILES.getValue(kind)), "observed-$kind-${processId.take(12)}-${++geoSnapshot}.dat")

    private fun routes() {
        val name = "fixture-routes"
        val provider = File(home, "$name.txt").apply { writeText("192.168.100.2/32\n") }
        val clients = "io.github.monadboxlab.clashpseudo.validation.clienta, io.github.monadboxlab.clashpseudo.validation.clientb"
        prepare(DIRECT + "ipv6: false\ndns: {enable: true, enhanced-mode: redir-host, nameserver: [192.168.100.2]}\n" +
            "tun: {stack: gvisor, mtu: 1420, route-address: [198.18.0.0/16], route-address-set: [$name], " +
            "dns-hijack: ['198.18.0.2:53'], include-package: [$clients]}\nrule-providers:\n" +
            "  $name: {type: file, behavior: ipcidr, format: text, path: $name.txt, interval: 0}\n", vpn = true)
        val specs = JSONArray().put(call(Contract.CORE_OPERATION_VPN_SPEC))
        val updates = JSONArray(); val rejected = JSONArray()
        val initial = value(specs.getJSONObject(0)).getLong("revision")
        val attached = arguments.optBoolean("attach")
        var service: PseudoVpnService? = null
        var descriptor: ParcelFileDescriptor? = null
        try {
            if (attached) {
                PseudoVpnService.awaitResourceHost(context, SystemClock.elapsedRealtime() + 30_000)
                service = checkNotNull(PseudoVpnService.instance)
                val specification = VpnSpecification.read(value(specs.getJSONObject(0)).toString())
                descriptor = service.establish(specification, "all", emptyList(), network).first
                val original = Os.fstat(descriptor.fileDescriptor)
                observations.put("attach", call(Contract.CORE_OPERATION_ATTACH,
                    JSONObject().put("revision", initial), tun = descriptor))
                    .put("originalRetainedAfterAttach", owns(descriptor.fd, original))
                    .put("attachedBeforeUpdates", call(Contract.CORE_OPERATION_SNAPSHOT))
            }
            for (prefix in listOf(31, 32)) {
                provider.writeText("192.168.100.2/$prefix\n")
                updates.put(call(Contract.CORE_OPERATION_RESOURCE_UPDATE, JSONObject().put("kind", "ruleProvider").put("name", name)))
                val expected = if (prefix == 31) 2L else 3L
                val end = SystemClock.elapsedRealtime() + 30_000
                var current: JSONObject
                do { current = call(Contract.CORE_OPERATION_VPN_SPEC)
                    if (value(current).getLong("revision") < expected) Thread.sleep(25)
                    check(SystemClock.elapsedRealtime() < end) { "Route revision was not updated" }
                } while (value(current).getLong("revision") < expected)
                specs.put(current)
                if (!attached) for (stale in if (prefix == 31) listOf(initial) else listOf(initial, 2L)) {
                    ParcelFileDescriptor.open(File("/dev/null"), ParcelFileDescriptor.MODE_READ_WRITE).use {
                        val original = Os.fstat(it.fileDescriptor)
                        val transferred = ParcelFileDescriptor.dup(it.fileDescriptor)
                        val fd = transferred.fd
                        rejected.put(invokeAttach(transferred, stale).put("revision", stale)
                            .put("originalRetained", owns(it.fd, original)).put("transferredConsumed", !owns(fd, original)))
                    }
                }
            }
            observations.put("specifications", specs).put("updates", updates).put("rejected", rejected)
                .put("changes", callbacks.changes).put("snapshot", call(Contract.CORE_OPERATION_SNAPSHOT))
        } finally {
            if (service != null) {
                try {
                    observations.put("routeStop", call(Contract.CORE_OPERATION_STOP))
                        .put("originalRetainedAfterStop", descriptor?.fileDescriptor?.valid() == true)
                } finally {
                    service.closeResources()
                    observations.put("originalClosed", descriptor?.fileDescriptor?.valid() == false)
                }
            }
        }
    }

    private fun matchingDescriptors(marker: File, original: StructStat): JSONArray {
        val path = marker.canonicalPath
        val matches = JSONArray()
        for (entry in checkNotNull(File("/proc/self/fd").listFiles())) {
            val target = try { Os.readlink(entry.path) }
            catch (error: ErrnoException) {
                if (error.errno != OsConstants.ENOENT) throw error
                continue
            }
            val fd = entry.name.toInt()
            if (target == path && owns(fd, original)) matches.put(fd)
        }
        return matches
    }

    private fun owns(fd: Int, original: StructStat): Boolean {
        val now = try { ParcelFileDescriptor.fromFd(fd).use { Os.fstat(it.fileDescriptor) } }
        catch (error: IOException) {
            val errno = generateSequence<Throwable>(error) { it.cause }.filterIsInstance<ErrnoException>().firstOrNull()
            if (errno?.errno != OsConstants.EBADF) throw error
            return false
        }
        return now.st_dev == original.st_dev && now.st_ino == original.st_ino
    }

    @Keep
    private class Callbacks(private val scene: Int) {
        val calls = AtomicInteger()
        val changes = JSONArray()
        private var invalidSocket: Throwable? = null
        @Keep fun protect(fd: Int): ByteArray = socket(fd)
        @Keep fun protectNetwork(fd: Int, networkHandle: String): ByteArray = socket(fd)
        private fun socket(fd: Int): ByteArray {
            calls.incrementAndGet()
            try { ParcelFileDescriptor.fromFd(fd).use { check(OsConstants.S_ISSOCK(Os.fstat(it.fileDescriptor).st_mode)) } }
            catch (error: Throwable) { invalidSocket = error; return failure(error) }
            if (scene == CoreFixtureContract.THROW_PROTECT) throw IllegalStateException("Injected protect callback failure")
            if (scene == CoreFixtureContract.REFUSE_PROTECT) return failure(IOException("Injected protect callback refusal"))
            return JSONObject().put("ok", true).put("error", JSONObject.NULL).toString().toByteArray()
        }
        @Keep fun systemDns(requestId: Long, wire: ByteArray): ByteArray = failure(IOException("Fixture does not provide system raw DNS"))
        @Keep fun systemLookup(requestId: Long, host: String, family: Int): ByteArray = failure(IOException("Fixture does not provide system host lookup"))
        @Keep fun cancelSystemDns(requestId: Long): ByteArray = JSONObject().put("cancelled", true).put("exited", true).toString().toByteArray()
        @Keep fun seedGeo(request: ByteArray): ByteArray = failure(IOException("Fixture geox-url is explicitly set; bundled Geo must not be requested"))
        @Keep fun specificationChanged(revision: Long, changed: Boolean) { synchronized(changes) { changes.put(JSONObject().put("revision", revision).put("changed", changed)) } }
        fun observation(): JSONObject = JSONObject().put("calls", calls.get()).put("invalidSocket", invalidSocket?.let(CoreErrors::json) ?: JSONObject.NULL)
        private fun failure(error: Throwable): ByteArray = JSONObject().put("ok", false).put("error", CoreErrors.json(error)).toString().toByteArray(Charsets.UTF_8)
    }

    companion object {
        const val DIRECT = "mode: rule\nfind-process-mode: off\nlog-level: info\ngeo-auto-update: false\n" +
            "geox-url: {geoip: '', geosite: '', mmdb: '', asn: ''}\nrules:\n  - MATCH,DIRECT\n"
        val GEO_FILES = mapOf("GeoIP" to "GeoIP.dat", "GeoSite" to "GeoSite.dat", "MMDB" to "Country.mmdb", "ASN" to "ASN.mmdb")
    }
}

/** Keep Geo fixture databases and raw bytes from each stage in this run's private cache directory; FD replies carry only file fingerprints. */
object GeoFixtureFiles {
    private const val MAX_BYTES = 64L * 1024 * 1024
    private val directoryName = Regex("validation-geo-p5-load-geo-[a-z0-9-]{4,32}")
    private val fileName = Regex("[A-Za-z0-9][A-Za-z0-9.-]{0,95}")

    fun directory(context: Context, fixture: JSONObject): File {
        val name = fixture.getString("directory")
        require(directoryName.matches(name)) { "Invalid Geo fixture cache directory" }
        val root = context.cacheDir.canonicalFile
        val directory = File(root, name)
        require(OsConstants.S_ISDIR(Os.lstat(directory.path).st_mode) && directory.canonicalFile == directory) {
            "Geo fixture must be an actual directory in this run's private cache"
        }
        return directory
    }

    private fun file(directory: File, name: String): File {
        require(directoryName.matches(directory.name) && fileName.matches(name) && !name.contains("..")) {
            "Invalid Geo fixture filename"
        }
        require(OsConstants.S_ISDIR(Os.lstat(directory.path).st_mode) && directory.canonicalFile == directory)
        return File(directory, name).also { require(it.parentFile == directory) }
    }

    fun read(directory: File, encoded: String): ByteArray {
        val record = JSONObject(encoded)
        val size = record.getLong("bytes").also { require(it in 1..MAX_BYTES) }
        val hash = record.getString("sha256").also { require(Regex("[0-9a-f]{64}").matches(it)) }
        val source = file(directory, record.getString("file"))
        val descriptor = Os.open(source.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
        try {
            val stat = Os.fstat(descriptor)
            require(OsConstants.S_ISREG(stat.st_mode) && stat.st_nlink == 1L && stat.st_size == size)
            val bytes = FileInputStream(descriptor).use { it.readBytes() }
            require(bytes.size.toLong() == size && sha256(bytes) == hash) { "Geo fixture raw byte fingerprint mismatch" }
            return bytes
        } finally {
            // Android FileInputStream(FileDescriptor) does not take ownership of the descriptor.
            Os.close(descriptor)
        }
    }

    fun snapshot(directory: File, source: File, name: String): String {
        val bytes = source.readBytes()
        require(bytes.size.toLong() in 1..MAX_BYTES)
        val target = file(directory, name)
        val descriptor = Os.open(target.path,
            OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_NOFOLLOW, 0x180)
        try {
            FileOutputStream(descriptor).use { it.write(bytes); it.flush(); it.fd.sync() }
        } finally {
            // Android FileOutputStream(FileDescriptor) does not take ownership of the descriptor.
            Os.close(descriptor)
        }
        return JSONObject().put("file", name).put("bytes", bytes.size).put("sha256", sha256(bytes)).toString()
    }

    private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it) }
}
