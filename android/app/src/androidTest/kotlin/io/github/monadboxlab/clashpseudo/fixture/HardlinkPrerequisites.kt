package io.github.monadboxlab.clashpseudo.fixture

import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Log
import org.json.JSONObject
import org.junit.Assume.assumeNoException
import java.io.File

/** 在测试的实际路径创建 hardlink；不支持时保留原 errno，并由 JUnit 记录 assumption。 */
object HardlinkPrerequisites {
    fun link(source: File, target: File, selector: String) {
        try {
            Os.link(source.path, target.path)
        } catch (error: ErrnoException) {
            if (error.errno !in setOf(OsConstants.EPERM, OsConstants.EACCES, OsConstants.EOPNOTSUPP,
                    OsConstants.ENOSYS, OsConstants.EXDEV, OsConstants.EROFS)) throw error
            val detail = JSONObject().put("status", "prerequisitesNotReady").put("prerequisite", "hardlink")
                .put("selector", selector).put("source", source.path).put("target", target.path)
                .put("errno", error.errno).put("error", error.toString()).toString()
            Log.w("HardlinkPrerequisites", detail, error)
            assumeNoException(detail, error)
            throw AssertionError("JUnit assumption 未终止测试", error)
        }
        val original = Os.lstat(source.path)
        val linked = Os.lstat(target.path)
        check(OsConstants.S_ISREG(original.st_mode) && original.st_dev == linked.st_dev &&
            original.st_ino == linked.st_ino && original.st_nlink > 1L && linked.st_nlink == original.st_nlink) {
            "hardlink 必须共享实际 inode 与 link count"
        }
    }
}
