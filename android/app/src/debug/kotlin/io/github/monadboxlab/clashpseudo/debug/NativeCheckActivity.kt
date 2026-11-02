package io.github.monadboxlab.clashpseudo.debug

import io.github.monadboxlab.clashpseudo.vpn.NativeSession

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.controls.SystemControls
import io.github.monadboxlab.clashpseudo.nativecore.CoreClient
import io.github.monadboxlab.clashpseudo.nativecore.CoreFrames
import io.github.monadboxlab.clashpseudo.nativecore.CorePrivateFiles
import io.github.monadboxlab.clashpseudo.nativecore.input.CoreInput
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID
import java.util.concurrent.Executors

class NativeCheckActivity : Activity() {
    private lateinit var status: TextView
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newFixedThreadPool(2)
    private var pending: String? = null
    private var message = "原生接口测试工具。"
    private var host = ""
    private var port = 0
    private var closed = false
    private val tick = object : Runnable {
        override fun run() {
            refresh()
            main.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(android.R.style.Theme_Material_Light_NoActionBar)
        super.onCreate(savedInstanceState)
        host = savedInstanceState?.getString("host") ?: intent.getStringExtra("host").orEmpty()
        port = savedInstanceState?.getInt("port") ?: intent.getIntExtra("port", 0)
        pending = savedInstanceState?.getString("pending")
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 40, 24, 24)
        }
        fun button(text: String, action: () -> Unit) {
            content.addView(Button(this).apply { this.text = text; setOnClickListener { action() } })
        }
        content.addView(TextView(this).apply { text = "原生接口测试（仅调试版）"; textSize = 20f })
        button("请求通知权限") {
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
            }
        }
        button("启动直连测试") { requestStart("direct") }
        button("启动代理测试") { requestStart("proxy") }
        button("测试代理订阅下载") { requestStart("provider") }
        button("测试代理订阅下载失败") { requestStart("missing") }
        button("测试代理订阅下载缓慢") { requestStart("slow") }
        button("启动无效配置测试") { requestStart("invalid") }
        button("停止接管") {
            SystemControls.request(this, "stop") { admission -> report("停止请求：$admission") }
        }
        button("流量检查") { worker.execute { runProbe(false) } }
        button("仅检查 TCP") { worker.execute { runProbe(false, tcpOnly = true) } }
        button("保持长连接") { worker.execute { runProbe(true) } }
        button("刷新状态") { refresh() }
        button("关闭测试页") { finish() }
        status = TextView(this).apply { textSize = 13f; setTextIsSelectable(true) }
        content.addView(status)
        setContentView(ScrollView(this).apply {
            addView(content)
            setOnApplyWindowInsetsListener { view, insets ->
                view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                    insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
                insets
            }
        })
        main.post(tick)
    }

    private fun fixtureAddress(): String {
        require(host.matches(Regex("[0-9.]+"))) { "请在启动测试页的命令中指定局域网 IPv4 地址" }
        val address = InetAddress.getByName(host)
        require(address.isSiteLocalAddress && port in 1024..65529) { "请指定局域网 IPv4 地址和 1024 至 65529 之间的端口" }
        return address.hostAddress!!
    }

    private fun requestStart(scene: String) {
        try {
            val ip = fixtureAddress()
            var body = assets.open("native/base.yaml").bufferedReader().use { it.readText() }
                .replace("@HOST@", ip).replace("@DNS@", (port + 2).toString())
            val route = if (scene == "proxy") "测试🌐" else "DIRECT"
            if (scene == "proxy") body += "\nproxies:\n  - {name: 测试🌐, type: socks5, server: $ip, port: ${port + 3}}\n"
            if (scene in listOf("provider", "missing", "slow")) {
                val resource = when (scene) { "missing" -> "missing"; "slow" -> "slow-provider"; else -> "provider" }
                body += "\nproxy-providers:\n  fixture:\n    type: http\n    url: http://$ip:$port/$resource\n    path: ./fixture-$scene.yaml\n    interval: 2\n    health-check: {enable: false}\n"
            }
            // 固定 SOCKS fixture 只处理 TCP，UDP 保持 DIRECT。
            body += "\nrules:\n  - DST-PORT,${port + 4},REJECT\n  - DST-PORT,$port,$route\n  - MATCH,DIRECT\n"
            if (scene == "invalid") body += "  - NOT-A-VALID-RULE,invalid\n"
            pending = body
            val consent = VpnService.prepare(this)
            if (consent == null) startPending() else {
                message = "等待系统 VPN 授权；取消不会启动接管。"
                startActivityForResult(consent, 1)
            }
        } catch (error: Exception) { report(error.toString()) }
        catch (error: LinkageError) { report(error.toString()) }
    }

    private fun startPending() {
        val body = pending ?: return
        pending = null
        worker.execute {
            val inputId = UUID.randomUUID().toString()
            val stage = File(AppFiles.work(this), "run-input-native-check-${UUID.randomUUID()}")
            try {
                check(stage.parentFile!!.isDirectory || stage.parentFile!!.mkdirs())
                check(stage.createNewFile())
                val input = CoreInput("native-check", 1, "rule", body.toByteArray(Charsets.UTF_8),
                    "{}".toByteArray(Charsets.UTF_8), name = "Native check")
                CorePrivateFiles.write(stage, input.snapshotBytes())
                val published = channel(Contract.CORE_CHANNEL_PUBLISH_RUN_INPUT, mapOf("path" to stage.path, "inputId" to inputId)) as Map<*, *>
                check(published["saved"] == true && published["durable"] == true)
                val identity = channel(Contract.CORE_CHANNEL_HANDSHAKE) as Map<*, *>
                val admittedAt = android.os.SystemClock.elapsedRealtime()
                val admission = channel(Contract.CORE_CHANNEL_SUBMIT, mapOf("operation" to Contract.CORE_OPERATION_PREPARE,
                    "identity" to identity + mapOf("generation" to 1L, "inputId" to inputId), "inputId" to inputId,
                    "arguments" to mapOf("purpose" to Contract.CORE_PURPOSE_RUNNING, "vpnIntent" to true,
                        "lanIntent" to false, "explicitStart" to true, "admittedAt" to admittedAt,
                        "deadline" to admittedAt + Contract.OPERATION_ORDINARY_TIMEOUT_MS))) as Map<*, *>
                check(admission["accepted"] == true)
                while (true) {
                    val frame = channel(Contract.CORE_CHANNEL_READ, mapOf("processId" to admission["processId"],
                        "requestId" to admission["requestId"])) as Map<*, *>
                    if ((frame["kind"] as Number).toInt() == Contract.CORE_IPC_FRAME_TERMINAL) {
                        val terminal = JSONObject(CoreFrames.utf8(frame["payload"] as ByteArray))
                        val receipt = frame["nativeReceipt"] as? Map<*, *>
                        check(receipt?.get("exited") == true) { "实际调用尚未退出：$frame" }
                        check(terminal.optBoolean("complete")) { "启动失败：$terminal\n$receipt" }
                        report("启动已完成；processId=${admission["processId"]}，请查看 VPN 状态并执行流量检查。")
                        break
                    }
                }
            } catch (error: Throwable) {
                report(error.stackTraceToString())
            } finally {
                if (stage.exists() && !stage.delete()) report("无法删除本次输入暂存文件：${stage.name}")
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 1) return
        if (resultCode == RESULT_OK) startPending() else {
            pending = null
            report("授权已取消，未启动接管。")
        }
    }

    private fun refresh() {
        if (closed) return
        status.text = "$message\npid=${android.os.Process.myPid()}\n${PseudoVpnService.session.snapshot()}\ncore=${CoreClient.get(this).status()}"
    }

    private fun channel(method: String, arguments: Any? = null): Any? {
        check(Looper.myLooper() != Looper.getMainLooper())
        val reply = CompletableFuture<Any?>()
        main.post {
            CoreClient.get(this).handle(MethodCall(method, arguments), object : MethodChannel.Result {
                override fun success(value: Any?) { reply.complete(value) }
                override fun error(code: String, message: String?, details: Any?) {
                    reply.completeExceptionally(java.io.IOException("$code: $message\n$details"))
                }
                override fun notImplemented() { reply.completeExceptionally(IllegalStateException("接口未实现：$method")) }
            })
        }
        return try { reply.get(130, TimeUnit.SECONDS) }
        catch (error: java.util.concurrent.ExecutionException) { throw error.cause ?: error }
    }

    private fun report(text: String) {
        Log.i("NativeCheck", text)
        main.post { if (!closed) { message = text; refresh() } }
    }

    private fun runProbe(hold: Boolean, tcpOnly: Boolean = false) {
        val id = UUID.randomUUID().toString()
        try {
            val ip = fixtureAddress()
            Socket().use { socket ->
                socket.connect(InetSocketAddress(ip, port), 3000)
                socket.soTimeout = 5000
                socket.getOutputStream().write("GET /${if (hold) "hold" else "ok"}/$id HTTP/1.0\r\nHost: fixture\r\n\r\n".toByteArray())
                if (hold) {
                    val buffer = ByteArray(512)
                    var reads = 0
                    while (socket.getInputStream().read(buffer) >= 0) {
                        if (reads++ % 25 == 0) Log.i("NativeCheck", "HOLD_ALIVE id=$id reads=$reads")
                    }
                } else {
                    val reply = socket.getInputStream().readBytes().toString(Charsets.UTF_8)
                    check(reply.contains(id)) { "HTTP 未返回本次标识" }
                }
            }
            if (hold) { report("HOLD_ENDED id=$id"); return }
            if (tcpOnly) { report("TCP_OK id=$id"); return }
            DatagramSocket().use { socket ->
                socket.soTimeout = 3000
                val bytes = id.toByteArray()
                socket.send(DatagramPacket(bytes, bytes.size, InetAddress.getByName(ip), port + 1))
                val reply = DatagramPacket(ByteArray(256), 256)
                socket.receive(reply)
                check(reply.data.copyOf(reply.length).contentEquals(bytes)) { "UDP response mismatch" }
            }
            val addresses = InetAddress.getAllByName("${id}.fixture.test").map { it.hostAddress }
            check(ip in addresses) { "DNS response mismatch: $addresses" }
            var rejected = false
            try {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress(ip, port + 4), 1500)
                    socket.soTimeout = 1500
                    socket.getOutputStream().write(id.toByteArray())
                    rejected = socket.getInputStream().read() == -1
                }
            } catch (_: java.io.IOException) { rejected = true }
            check(rejected) { "拒绝规则未生效" }
            report("PROBE_OK id=$id tcp=ok udp=ok dns=$addresses reject=observed")
        } catch (error: Exception) { report("PROBE_${if (hold) "HOLD_END" else "FAILED"} id=$id $error") }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("pending", pending)
        outState.putString("host", host)
        outState.putInt("port", port)
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        closed = true
        main.removeCallbacks(tick)
        worker.shutdownNow()
        super.onDestroy()
    }
}
