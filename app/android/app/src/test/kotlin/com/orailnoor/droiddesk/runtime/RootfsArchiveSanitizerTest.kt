package com.orailnoor.droiddesk.runtime

import org.apache.commons.compress.archivers.tar.TarArchiveEntry
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.archivers.tar.TarArchiveOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.file.Files

class RootfsArchiveSanitizerTest {
    @Test
    fun stripsKaliArchiveFolderAndPreservesSystemdEscapedFilename() {
        val tempDirectory = Files.createTempDirectory("droiddesk-kali-archive-test").toFile()
        try {
            val source = File(tempDirectory, "source.tar")
            val sanitized = File(tempDirectory, "sanitized.tar")
            val payload = "systemd-unit-test".toByteArray()
            val escapedName =
                "kali-arm64/usr/lib/systemd/system/systemd\\x2dmute\\x2dconsole.slice"

            TarArchiveOutputStream(FileOutputStream(source)).use { tar ->
                val root = TarArchiveEntry("kali-arm64/")
                root.mode = 0b111101101
                root.size = 0
                tar.putArchiveEntry(root)
                tar.closeArchiveEntry()

                val file = TarArchiveEntry(escapedName)
                file.mode = 0b110100100
                file.size = payload.size.toLong()
                tar.putArchiveEntry(file)
                tar.write(payload)
                tar.closeArchiveEntry()
            }

            val result = RootfsArchiveSanitizer.sanitize(
                sourceArchive = source,
                targetTar = sanitized,
                xzCompressed = false,
                stripTopLevelDirectory = "kali-arm64",
                maxEntries = 100,
                maxExpandedBytes = 1024 * 1024,
                bufferSize = 4096,
            )

            assertEquals(2, result.entries)
            assertEquals(1, result.regularFiles)
            assertEquals(0, result.directories)
            assertEquals(0, result.skippedSpecialFiles)

            TarArchiveInputStream(FileInputStream(sanitized)).use { tar ->
                val entry = tar.nextEntry
                assertNotNull(entry)
                assertEquals(
                    "usr/lib/systemd/system/systemd\\x2dmute\\x2dconsole.slice",
                    entry.name,
                )
                assertArrayEquals(payload, tar.readBytes())
                assertNull(tar.nextEntry)
            }
        } finally {
            tempDirectory.deleteRecursively()
        }
    }

    @Test
    fun rejectsKaliArchiveMembersOutsideTheExpectedRoot() {
        val tempDirectory = Files.createTempDirectory("droiddesk-kali-archive-invalid").toFile()
        try {
            val source = File(tempDirectory, "source.tar")
            val sanitized = File(tempDirectory, "sanitized.tar")
            val file = TarArchiveEntry("ubuntu/etc/passwd")
            file.size = 0
            TarArchiveOutputStream(FileOutputStream(source)).use { tar ->
                tar.putArchiveEntry(file)
                tar.closeArchiveEntry()
            }

            assertThrows(SecurityException::class.java) {
                RootfsArchiveSanitizer.sanitize(
                    sourceArchive = source,
                    targetTar = sanitized,
                    xzCompressed = false,
                    stripTopLevelDirectory = "kali-arm64",
                    maxEntries = 100,
                    maxExpandedBytes = 1024 * 1024,
                    bufferSize = 4096,
                )
            }
            assertFalse(sanitized.exists())
        } finally {
            tempDirectory.deleteRecursively()
        }
    }
}
