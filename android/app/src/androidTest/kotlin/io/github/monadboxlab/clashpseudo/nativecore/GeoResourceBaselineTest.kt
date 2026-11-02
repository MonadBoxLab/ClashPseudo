package io.github.monadboxlab.clashpseudo.nativecore

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import io.github.monadboxlab.clashpseudo.storage.AppFiles
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.app.AppWorkService
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

/** 按 nonce 导出已停止应用的 GeoIP，随后以只读方式验证。 */
class GeoResourceBaselineTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val nonce = "p5-load-geo-r7w7"

    @Test fun exportStoppedGeoIpBaselineWithoutChangingTheResource() {
        val context = checkedContext()
        val stopped = assertStopped()
        CoreResourceGate.forApplication(context).exclusive {

        // 内核目录由生产 AppFiles 接口提供。
        val home = AppFiles.core(context)
        val homeBefore = existing(home)
        assertTrue("正式内核目录必须为目录，不能为 symlink",
            OsConstants.S_ISDIR(homeBefore.st_mode))
        val source = File(home, "GeoIP.dat")
        val before = sourceStat(source)

        val external = context.getExternalFilesDir(null)
        assertNotNull("应用的 external files 目录不可用", external)
        val directory = File(external!!, "validation-geo-$nonce")
        assertTrue("baseline 目录必须新建，不能复用", directory.mkdir())
        val directoryBefore = existing(directory)
        assertTrue("新 baseline 目录不能为 symlink",
            OsConstants.S_ISDIR(directoryBefore.st_mode))
        val destination = File(directory, "GeoIP.dat")
        assertTrue("baseline 文件必须新建，不能覆盖", destination.createNewFile())
        val destinationBefore = existing(destination)
        assertTrue("新 baseline 文件必须为普通文件", OsConstants.S_ISREG(destinationBefore.st_mode))
        assertEquals(0L, destinationBefore.st_size)
        assertEquals(1L, destinationBefore.st_nlink)

        // 以 NOFOLLOW 打开刚创建的目标文件。
        val outputFd = Os.open(destination.absolutePath,
            OsConstants.O_WRONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
        val captured = try {
            sameSource(destinationBefore, Os.fstat(outputFd))
            val copied = FileOutputStream(outputFd).use { output ->
                val result = fingerprint(source, before, output)
                output.flush()
                output.fd.sync()
                result
            }
            assertEquals("同步后的 baseline 大小不符", copied.first, Os.fstat(outputFd).st_size)
            copied
        } finally {
            // Android FileOutputStream(FileDescriptor) 不取得此 descriptor 的 ownership。
            Os.close(outputFd)
        }
        val (bytes, sha256) = captured

        assertStopped(stopped)
        val exported = sourceStat(destination)
        assertEquals(destinationBefore.st_dev, exported.st_dev)
        assertEquals(destinationBefore.st_ino, exported.st_ino)
        assertEquals(destinationBefore.st_nlink, exported.st_nlink)
        assertEquals(bytes, exported.st_size)
        assertEquals("保存的 baseline 必须与捕获内容相同", captured, fingerprint(destination, exported))
        assertEquals("正式 GeoIP 必须仍与捕获内容相同", captured, fingerprint(source, before))
        assertStopped(stopped)
        sameSource(before, existing(source))
        sameSource(exported, existing(destination))
        sameDirectory(homeBefore, existing(home))
        sameDirectory(directoryBefore, existing(directory))
        Log.i("PseudoGeoBaseline",
            "nonce=$nonce absolutePath=${destination.absolutePath} bytes=$bytes sha256=$sha256")
        // 失败时保留原资源与本次导出文件。
        }
    }

    @Test fun verifyStoppedGeoIpMatchesProtectedBaseline() {
        val context = checkedContext()
        val stopped = assertStopped()
        CoreResourceGate.forApplication(context).exclusive {
        val home = AppFiles.core(context)
        val homeBefore = existing(home)
        assertTrue("正式内核目录必须为目录，不能为 symlink",
            OsConstants.S_ISDIR(homeBefore.st_mode))
        val external = context.getExternalFilesDir(null)
        assertNotNull("应用的 external files 目录不可用", external)
        val directory = File(external!!, "validation-geo-$nonce")
        val directoryBefore = existing(directory)
        assertTrue("受保护的 baseline 目录不能为 symlink",
            OsConstants.S_ISDIR(directoryBefore.st_mode))
        val baseline = File(directory, "GeoIP.dat")
        val baselineBefore = sourceStat(baseline)
        val source = File(home, "GeoIP.dat")
        val sourceBefore = sourceStat(source)
        val expected = fingerprint(baseline, baselineBefore)
        val actual = fingerprint(source, sourceBefore)
        assertEquals("当前 GeoIP 字节数必须等于受保护的 baseline", expected.first, actual.first)
        assertEquals("当前 GeoIP SHA-256 必须等于受保护的 baseline", expected.second, actual.second)
        assertStopped(stopped)
        sameSource(baselineBefore, existing(baseline))
        sameSource(sourceBefore, existing(source))
        sameDirectory(homeBefore, existing(home))
        sameDirectory(directoryBefore, existing(directory))
        Log.i("PseudoGeoBaseline",
            "nonce=$nonce absolutePath=${source.absolutePath} baselinePath=${baseline.absolutePath} " +
                "bytes=${actual.first} sha256=${actual.second} matches=true")
        }
    }

    private fun checkedContext(): Context {
        assertEquals("必须显式提供相同 nonce", nonce,
            InstrumentationRegistry.getArguments().getString("nonce"))
        val context = instrumentation.targetContext.applicationContext
        assertEquals("baseline 仅属于主应用 package",
            "io.github.monadboxlab.clashpseudo", context.packageName)
        assertTrue("主应用 package 必须为 debug build",
            context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
        return context
    }

    private fun sourceStat(file: File): StructStat = existing(file).also { stat ->
        assertTrue("GeoIP 必须为普通文件，不能为 symlink", OsConstants.S_ISREG(stat.st_mode))
        assertEquals("GeoIP 不能有其他 hard link", 1L, stat.st_nlink)
        assertTrue("GeoIP 现有内容必须为 1..32 MiB",
            stat.st_size in 1L..(32L * 1024 * 1024))
    }

    private fun fingerprint(source: File, before: StructStat, output: FileOutputStream? = null): Pair<Long, String> {
        val digest = MessageDigest.getInstance("SHA-256")
        var bytes = 0L
        val descriptor = Os.open(source.absolutePath,
            OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
        try {
            sameSource(before, Os.fstat(descriptor))
            FileInputStream(descriptor).use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    bytes += count
                    assertTrue("读取期间 GeoIP 增长", bytes <= before.st_size)
                    digest.update(buffer, 0, count)
                    output?.write(buffer, 0, count)
                }
                assertEquals("读取期间 GeoIP 字节数变化", before.st_size, bytes)
                sameSource(before, Os.fstat(descriptor))
            }
        } finally {
            // Android FileInputStream(FileDescriptor) 不取得此 descriptor 的 ownership。
            Os.close(descriptor)
        }
        sameSource(before, existing(source))
        return bytes to digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun sameDirectory(before: StructStat, after: StructStat) {
        assertTrue("目录必须保持为目录，不能变为 symlink", OsConstants.S_ISDIR(after.st_mode))
        assertEquals("目录 device 变化", before.st_dev, after.st_dev)
        assertEquals("目录 inode 变化", before.st_ino, after.st_ino)
    }

    private fun assertStopped(expected: Pair<Long, Long>? = null): Pair<Long, Long> {
        val deadline = SystemClock.elapsedRealtime() + 35_000
        var identity = expected
        while (true) {
            val expectedIdentity = identity
            val task = FutureTask {
                val session = PseudoVpnService.session.snapshot()
                val core = PseudoVpnService.core.snapshot()
                assertEquals(NativeSession.Phase.STOPPED, session.phase)
                assertEquals(CoreHost.Phase.EMPTY, core.phase)
                assertFalse("VPN Service 必须实际停止", CoreIpcTestDriver.servicePresent(instrumentation.targetContext, PseudoVpnService::class.java))
                assertNull("AppWorkService 必须实际停止", AppWorkService.instance)
                val currentIdentity = session.generation to core.generation
                if (expectedIdentity != null) {
                    assertEquals("停止后的 session/core identity 不能变化", expectedIdentity, currentIdentity)
                }
                val state = AppBridge.runtimeState()
                for (key in listOf("resourceBusy", "storageRestoring", "pendingStart",
                    "pendingSystemStart", "pendingRestore")) {
                    assertEquals("等待空闲期间 $key 必须保持 false", false, state[key])
                }
                val command = AppBridge.command
                val idle = !AppBridge.logic.busy && AppBridge.operationId == null && command == null &&
                    state["writerBusy"] == false && state["scheduleBusy"] == false
                if (!idle) {
                    // 等待启动时的 schedule reconciliation 实际结束，再检查业务空闲状态。
                    assertEquals("仅允许正常启动校准仍在执行", "syncSchedules", command?.get("action"))
                }
                currentIdentity to (idle && state["storageReady"] == true)
            }
            instrumentation.runOnMainSync(task)
            val (currentIdentity, idle) = task.get(10, TimeUnit.SECONDS)
            identity = currentIdentity
            CoreIpcTestDriver.assertNoGoInApplication()
            val coreStatus = CoreClient.get(instrumentation.targetContext).status()
            assertTrue("只能读取未启动或已退出进程的 baseline：$coreStatus",
                coreStatus["phase"] in setOf(Contract.CORE_PHASE_DISCONNECTED, Contract.CORE_PHASE_EXITED))
            if (idle) return currentIdentity
            assertTrue("等待正常启动校准及实际 writer 退出超时",
                SystemClock.elapsedRealtime() < deadline)
            Thread.sleep(25)
        }
    }

    private fun existing(file: File): StructStat = try {
        Os.lstat(file.absolutePath)
    } catch (error: ErrnoException) {
        throw AssertionError("baseline 材料缺失或不可访问： ${file.absolutePath}", error)
    }

    private fun sameSource(before: StructStat, after: StructStat) {
        assertTrue("文件必须保持为普通文件，不能变为 symlink", OsConstants.S_ISREG(after.st_mode))
        assertEquals("文件 device 变化", before.st_dev, after.st_dev)
        assertEquals("文件 inode 变化", before.st_ino, after.st_ino)
        assertEquals("文件大小变化", before.st_size, after.st_size)
        assertEquals("文件 hard link 数变化", before.st_nlink, after.st_nlink)
        assertEquals("文件 mtime 变化", before.st_mtime, after.st_mtime)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            assertEquals("文件 mtime 秒数变化", before.st_mtim.tv_sec, after.st_mtim.tv_sec)
            assertEquals("文件 mtime 纳秒数变化", before.st_mtim.tv_nsec, after.st_mtim.tv_nsec)
        }
    }
}
