package com.orailnoor.droiddesk.runtime

import org.apache.commons.compress.archivers.tar.TarArchiveEntry
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.archivers.tar.TarArchiveOutputStream
import org.tukaani.xz.XZInputStream
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.zip.GZIPInputStream

/**
 * Rewrites a downloaded rootfs tarball into a safe, normalized tar archive.
 * The original archive is SHA-256 verified before this component is called.
 *
 * It preserves ordinary files, directories, symlinks and hardlinks. Device
 * nodes and FIFOs are omitted because Android does not allow an unprivileged
 * app to create them; DroidDesk bind-mounts Android /dev and /dev/shm at runtime.
 */
internal object RootfsArchiveSanitizer {
    data class Result(
        val entries: Int,
        val regularFiles: Int,
        val directories: Int,
        val links: Int,
        val skippedSpecialFiles: Int,
        val expandedBytes: Long,
    )

    fun sanitize(
        sourceArchive: File,
        targetTar: File,
        xzCompressed: Boolean,
        maxEntries: Int,
        maxExpandedBytes: Long,
        bufferSize: Int,
    ): Result {
        val parent = targetTar.parentFile
            ?: throw IllegalStateException("Sanitized archive has no parent directory")
        if (!parent.exists() && !parent.mkdirs()) {
            throw IllegalStateException("Could not create sanitized archive directory")
        }
        if (targetTar.exists() && !targetTar.delete()) {
            throw IllegalStateException("Could not replace the previous sanitized archive")
        }

        var entries = 0
        var files = 0
        var directories = 0
        var links = 0
        var skippedSpecial = 0
        var expandedBytes = 0L

        try {
            val rawInput = BufferedInputStream(FileInputStream(sourceArchive), bufferSize)
            val decodedInput = if (xzCompressed) XZInputStream(rawInput) else GZIPInputStream(rawInput, bufferSize)

            decodedInput.use { decoded ->
                TarArchiveInputStream(decoded, "UTF-8").use { tarInput ->
                    BufferedOutputStream(FileOutputStream(targetTar), bufferSize).use { bufferedOutput ->
                        TarArchiveOutputStream(bufferedOutput).use { tarOutput ->
                            tarOutput.setLongFileMode(TarArchiveOutputStream.LONGFILE_POSIX)
                            tarOutput.setBigNumberMode(TarArchiveOutputStream.BIGNUMBER_POSIX)

                            while (true) {
                                val sourceEntry = tarInput.nextEntry ?: break
                                entries++
                                if (entries > maxEntries) {
                                    throw SecurityException("Rootfs archive contains too many entries")
                                }

                                if (sourceEntry.isSparse) {
                                    throw SecurityException(
                                        "Sparse rootfs archive entries are not supported: ${sourceEntry.name.take(200)}"
                                    )
                                }
                                val normalizedName = ArchivePathValidator.normalizeEntryName(sourceEntry.name)
                                val isDirectory = sourceEntry.isDirectory
                                if (normalizedName.isEmpty()) {
                                    if (isDirectory) continue
                                    throw SecurityException(
                                        "Archive file resolves to the extraction root: ${sourceEntry.name.take(240)}"
                                    )
                                }

                                val size = sourceEntry.size
                                if (size < 0L || expandedBytes > maxExpandedBytes - size) {
                                    throw SecurityException("Rootfs archive exceeds the expanded-size limit")
                                }
                                expandedBytes += size

                                if (
                                    sourceEntry.isCharacterDevice ||
                                    sourceEntry.isBlockDevice ||
                                    sourceEntry.isFIFO
                                ) {
                                    skippedSpecial++
                                    continue
                                }

                                val outputEntry = copyMetadata(sourceEntry, normalizedName)

                                when {
                                    sourceEntry.isSymbolicLink -> {
                                        outputEntry.setLinkName(
                                            ArchivePathValidator.validateSymbolicLinkTarget(
                                                normalizedName,
                                                sourceEntry.linkName,
                                            )
                                        )
                                        links++
                                    }
                                    sourceEntry.isLink -> {
                                        val linkTarget = ArchivePathValidator.normalizeEntryName(
                                            sourceEntry.linkName,
                                            stripLeadingParents = false,
                                        )
                                        if (linkTarget.isEmpty()) {
                                            throw SecurityException("Hardlink target resolves to the extraction root")
                                        }
                                        outputEntry.setLinkName(linkTarget)
                                        links++
                                    }
                                    isDirectory -> directories++
                                    else -> files++
                                }

                                tarOutput.putArchiveEntry(outputEntry)
                                if (!isDirectory && !sourceEntry.isSymbolicLink && !sourceEntry.isLink) {
                                    tarInput.copyTo(tarOutput, bufferSize)
                                }
                                tarOutput.closeArchiveEntry()
                            }

                            if (entries == 0) throw SecurityException("Rootfs archive is empty")
                            tarOutput.finish()
                        }
                    }
                }
            }

            if (!targetTar.isFile || targetTar.length() <= 0L) {
                throw IllegalStateException("Sanitized rootfs archive was not created")
            }

            return Result(entries, files, directories, links, skippedSpecial, expandedBytes)
        } catch (error: Exception) {
            runCatching { targetTar.delete() }
            throw error
        }
    }

    private fun copyMetadata(source: TarArchiveEntry, normalizedName: String): TarArchiveEntry {
        val result = TarArchiveEntry(normalizedName, source.linkFlag)
        result.setMode(source.mode)
        result.setUserId(source.longUserId)
        result.setGroupId(source.longGroupId)
        result.setNames(source.userName, source.groupName)
        result.setModTime(source.modTime)
        result.setDevMajor(source.devMajor)
        result.setDevMinor(source.devMinor)
        result.setSize(source.size)

        // Preserve extended attributes and other non-path PAX metadata, but do
        // not copy raw path/linkpath fields that could override normalized names.
        val blockedPaxKeys = setOf("path", "linkpath", "size", "uid", "gid", "uname", "gname", "mtime")
        source.extraPaxHeaders.forEach { (key, value) ->
            if (key !in blockedPaxKeys) result.addPaxHeader(key, value)
        }
        return result
    }
}
