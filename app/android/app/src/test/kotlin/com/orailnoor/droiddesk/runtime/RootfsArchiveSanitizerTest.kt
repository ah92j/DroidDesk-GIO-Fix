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
import org.tukaani.xz.LZMA2Options
import org.tukaani.xz.XZOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.file.Files

class RootfsArchiveSanitizerTest {
    @Test
    fun stripsKaliArchiveFolderAndPreservesSystemdEscapedFilename() {
        val tempDirectory = Files.createTempDirectory("droiddesk-kali-archive-test").toFile()
        try {
            val sourceTar = File(tempDirectory, "source.tar")
            val sourceXz = File(tempDirectory, "source.tar.xz")
            val sanitized = File(tempDirectory, "sanitized.tar")
            val payload = "systemd-unit-test".toByteArray()
            val escapedName =
                "kali-arm64/usr/lib/systemd/system/systemd\\x2dmute\\x2dconsole.slice"

            writeXzTar(sourceTar, sourceXz, escapedName, payload)

            val result = RootfsArchiveSanitizer.sanitize(
                sourceArchive = sourceXz,
                targetTar = sanitized,
                xzCompressed = true,
                stripTopLevelDirectory = "kali-arm64",
                maxEntries = 100,
                maxExpandedBytes = 1024 * 1024,
                bufferSize = 4096,
            )

            assertEquals(1, result.entries)
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
            val sourceTar = File(tempDirectory, "source.tar")
            val sourceXz = File(tempDirectory, "source.tar.xz")
            val sanitized = File(tempDirectory, "sanitized.tar")

            writeXzTar(sourceTar, sourceXz, "ubuntu/etc/passwd", byteArrayOf())

            assertThrows(SecurityException::class.java) {
                RootfsArchiveSanitizer.sanitize(
                    sourceArchive = sourceXz,
                    targetTar = sanitized,
                    xzCompressed = true,
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

    private fun writeXzTar(
        tarFile: File,
        xzFile: File,
        entryName: String,
        payload: ByteArray,
    ) {
        TarArchiveOutputStream(FileOutputStream(tarFile)).use { tar ->
            val entry = TarArchiveEntry(entryName)
            entry.mode = 0b110100100
            entry.size = payload.size.toLong()
            tar.putArchiveEntry(entry)
            tar.write(payload)
            tar.closeArchiveEntry()
        }

        XZOutputStream(FileOutputStream(xzFile), LZMA2Options()).use { xz ->
            FileInputStream(tarFile).use { input -> input.copyTo(xz) }
        }
    }
}
