package com.orailnoor.droiddesk.runtime

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import java.security.MessageDigest
import java.util.zip.GZIPInputStream
import kotlin.concurrent.thread

/**
 * Manages Linux rootfs downloads, extraction, and lifecycle.
 *
 * Rootfs images are standard arm64 Linux distributions downloaded from
 * official or community mirrors. They are used only by DroidDesk's rooted
 * chroot path; non-root devices use the native Termux/TUR runtime instead.
 *
 * Download flow:
 *   1. User selects distro in Flutter wizard
 *   2. Download tarball (~300-500 MB compressed) with progress
 *   3. Extract to app's private storage (2-4 GB uncompressed)
 *   4. Configure user, sudo, apt sources
 */
class RootfsManager(private val context: Context) {

    companion object {
        private const val TAG = "RootfsManager"
        private const val BUFFER_SIZE = 8192

        // Official rootfs download URLs (arm64)
        // Minimal rootfs tarballs reused as rooted chroot filesystems.
        val DISTRO_URLS = mapOf(
            "ubuntu" to "https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-arm64.tar.gz",
            "alpine" to "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-minirootfs-3.20.0-aarch64.tar.gz",
            "kali" to "https://kali.download/nethunter-images/kali-2026.3/rootfs/kali-nethunter-rootfs-minimal-arm64.tar.xz"
        )
        val DISTRO_SHA256 = mapOf(
            "ubuntu" to "04207713ece899c3740823d33690441ad3a7f0ded1101aca744e2b0f37ac7ff2",
            "alpine" to "83a79199bf3112c65e62ddf1732b051daf62ed2ddf5a8413c440dc25956116f0",
            "kali" to "96aeced81a857a987715a14417af05c2934e3e19052d6151c398a1c215448b60"
        )

        val DISTRO_NAMES = mapOf(
            "ubuntu" to "Ubuntu 24.04 Base",
            "alpine" to "Alpine Linux 3.20",
            "kali" to "Kali Linux (NetHunter Minimal)"
        )
    }

    private val baseDir: File get() = context.filesDir
    private val rootfsDir: File get() = File(baseDir, "rootfs")
    private val downloadDir: File get() = File(baseDir, "downloads")
    private val configFile: File get() = File(baseDir, "distro.conf")
    private val deConfigFile: File get() = File(baseDir, "de.conf")

    // ── Status ──

    fun getInstalledDistro(): String {
        return if (configFile.exists()) configFile.readText().trim() else ""
    }

    fun getInstalledDE(): String {
        return if (deConfigFile.exists()) deConfigFile.readText().trim() else ""
    }

    fun getMissingPackages(): List<String> {
        if (!isRootfsReady()) return listOf("rootfs")
        val de = getInstalledDE().ifEmpty { "xfce4" }
        val deBin = when (de) {
            "lxqt" -> "usr/bin/lxqt-session"
            "mate" -> "usr/bin/mate-session"
            "kde" -> "usr/bin/startplasma-x11"
            else -> "usr/bin/xfce4-session"
        }
        return if (File(rootfsDir, deBin).exists()) {
            emptyList()
        } else {
            listOf(de)
        }
    }

    fun getRootfsPath(): String {
        return rootfsDir.absolutePath
    }

    fun getRootfsSizeMB(): Long {
        return if (rootfsDir.exists()) {
            calculateDirSize(rootfsDir) / (1024 * 1024)
        } else 0
    }

    fun isRootfsReady(): Boolean {
        // Check for critical directories that indicate a valid rootfs
        return rootfsDir.exists() &&
                File(rootfsDir, "bin").exists() &&
                File(rootfsDir, "usr").exists() &&
                File(rootfsDir, "etc").exists()
    }

    // ── Download ──

    /**
     * Download a distro rootfs tarball with progress callbacks.
     * Runs on a background thread.
     */
    fun downloadRootfs(
        distro: String,
        onProgress: (progress: Double, status: String) -> Unit
    ) {
        thread(name = "rootfs-download") {
            try {
                val url = DISTRO_URLS[distro]
                    ?: throw IllegalArgumentException("Unknown distro: $distro")
                val distroName = DISTRO_NAMES[distro] ?: distro

                downloadDir.mkdirs()
                val targetFile = File(downloadDir, "${distro}-rootfs.tar." + (if (distro == "kali") "xz" else "gz"))

                onProgress(0.0, "Connecting to download server...")
                Log.i(TAG, "Downloading $distroName from $url")

                var downloadedBytes = 0L

                if (targetFile.exists()) {
                    downloadedBytes = targetFile.length()
                }

                val connection = openHttpsConnection(url, downloadedBytes)

                if (connection.responseCode == 416) {
                    connection.disconnect()
                    targetFile.delete()
                    throw IllegalStateException(
                        "Resume request rejected (HTTP 416). Partial download removed."
                    )
                }

                if (connection.responseCode == 200 && downloadedBytes > 0L) {
                    targetFile.delete()
                    downloadedBytes = 0L
                }

                downloadFromConnection(
                    connection,
                    targetFile,
                    distroName,
                    downloadedBytes,
                    onProgress
                )
                verifySha256(
                    targetFile,
                    DISTRO_SHA256[distro]
                        ?: throw IllegalStateException("Missing SHA-256 for $distro")
                )

                // Save distro selection
                configFile.writeText(distro)

                onProgress(1.0, "$distroName downloaded successfully")
                Log.i(TAG, "Download complete: ${targetFile.absolutePath}")

            } catch (e: Exception) {
                Log.e(TAG, "Download failed: ${e.message}", e)
                onProgress(-1.0, "Download failed: ${e.message}")
            }
        }
    }
    private fun openHttpsConnection(
        rawUrl: String,
        rangeStart: Long
    ): HttpsURLConnection {
        var currentUrl = URL(rawUrl)

        for (redirectCount in 0..5) {
            if (
                !currentUrl.protocol.equals("https", ignoreCase = true) ||
                currentUrl.userInfo != null
            ) {
                throw SecurityException("Blocked non-HTTPS download URL")
            }

            val connection = currentUrl.openConnection() as? HttpsURLConnection
                ?: throw SecurityException("HTTPS connection required")

            connection.instanceFollowRedirects = false
            connection.connectTimeout = 30000
            connection.readTimeout = 30000
            connection.requestMethod = "GET"
            connection.setRequestProperty("Accept-Encoding", "identity")

            if (rangeStart > 0L) {
                connection.setRequestProperty("Range", "bytes=$rangeStart-")
            }

            val responseCode = connection.responseCode

            if (responseCode in setOf(301, 302, 303, 307, 308)) {
                val location = connection.getHeaderField("Location")
                connection.disconnect()

                if (location.isNullOrBlank()) {
                    throw SecurityException("Redirect location is missing")
                }

                if (redirectCount == 5) {
                    throw SecurityException("Too many download redirects")
                }

                val redirectedUrl = URL(currentUrl, location)

                if (
                    !redirectedUrl.protocol.equals("https", ignoreCase = true) ||
                    redirectedUrl.userInfo != null
                ) {
                    throw SecurityException("Blocked insecure download redirect")
                }

                currentUrl = redirectedUrl
                continue
            }

            return connection
        }

        throw IllegalStateException("Download redirect limit exceeded")
    }
    private fun verifySha256(file: File, expectedSha256: String) {
        if (!file.isFile) {
            throw IllegalStateException("Downloaded rootfs file is missing")
        }

        if (!expectedSha256.matches(Regex("^[a-fA-F0-9]{64}$"))) {
            throw IllegalArgumentException("Invalid expected SHA-256")
        }

        val digest = MessageDigest.getInstance("SHA-256")

        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(BUFFER_SIZE)

            while (true) {
                val bytesRead = input.read(buffer)
                if (bytesRead < 0) break

                digest.update(buffer, 0, bytesRead)
            }
        }

        val actualSha256 = digest.digest().joinToString("") {
            "%02x".format(it.toInt() and 0xff)
        }

        if (!actualSha256.equals(expectedSha256, ignoreCase = true)) {
            if (!file.delete()) {
                throw SecurityException(
                    "SHA-256 mismatch and invalid file could not be deleted"
                )
            }

            throw SecurityException(
                "SHA-256 verification failed. Downloaded file was removed."
            )
        }

        Log.i(TAG, "Rootfs SHA-256 verification passed")
        }

        private fun downloadFromConnection(
        connection: HttpURLConnection,
        targetFile: File,
        distroName: String,
        initialDownloadedBytes: Long,
        onProgress: (Double, String) -> Unit
    ) {
        try {
            fun rejectDownload(message: String): Nothing {
                targetFile.delete()
                throw IllegalStateException(message)
            }

            if (initialDownloadedBytes < 0L) {
                rejectDownload("Invalid initial download size")
            }

            val responseCode = connection.responseCode

            if (responseCode == 416) {
                rejectDownload("Resume request rejected (HTTP 416)")
            }

            if (initialDownloadedBytes > 0L &&
                responseCode != HttpURLConnection.HTTP_PARTIAL
            ) {
                rejectDownload("Server did not honor download resume")
            }

            if (initialDownloadedBytes == 0L &&
                responseCode != HttpURLConnection.HTTP_OK
            ) {
                rejectDownload("Unexpected download HTTP status: $responseCode")
            }

            val responseLength = connection.contentLengthLong
            var expectedResponseBytes: Long? = null
            var expectedTotalBytes: Long? = null

            if (initialDownloadedBytes > 0L) {
                val contentRange = connection.getHeaderField("Content-Range")
                val rangeMatch = Regex(
                    "^bytes ([0-9]+)-([0-9]+)/([0-9]+)$",
                    RegexOption.IGNORE_CASE
                ).matchEntire(contentRange?.trim().orEmpty())
                    ?: rejectDownload("Missing or invalid Content-Range")

                val rangeStart = rangeMatch.groupValues[1].toLongOrNull()
                    ?: rejectDownload("Invalid Content-Range start")

                val rangeEnd = rangeMatch.groupValues[2].toLongOrNull()
                    ?: rejectDownload("Invalid Content-Range end")

                val rangeTotal = rangeMatch.groupValues[3].toLongOrNull()
                    ?: rejectDownload("Invalid Content-Range total")

                if (
                    rangeStart != initialDownloadedBytes ||
                    rangeEnd < rangeStart ||
                    rangeTotal <= rangeEnd ||
                    rangeEnd != rangeTotal - 1L
                ) {
                    rejectDownload("Content-Range boundaries are invalid")
                }

                val rangeLength = rangeEnd - rangeStart + 1L

                if (
                    responseLength == 0L ||
                    (responseLength > 0L && responseLength != rangeLength)
                ) {
                    rejectDownload("Content-Length does not match Content-Range")
                }

                expectedResponseBytes = rangeLength
                expectedTotalBytes = rangeTotal
            } else {
                if (responseLength == 0L) {
                    rejectDownload("Server returned an empty download")
                }

                if (responseLength > 0L) {
                    expectedResponseBytes = responseLength
                    expectedTotalBytes = responseLength
                }
            }

            var downloadedBytes = initialDownloadedBytes
            var receivedBytes = 0L
            val buffer = ByteArray(BUFFER_SIZE)

            connection.inputStream.use { input ->
                FileOutputStream(
                    targetFile,
                    initialDownloadedBytes > 0L
                ).use { output ->
                    while (true) {
                        val bytesRead = input.read(buffer)
                        if (bytesRead < 0) break
                        if (bytesRead == 0) continue

                        val expected = expectedResponseBytes
                        if (
                            expected != null &&
                            receivedBytes > expected - bytesRead
                        ) {
                            rejectDownload("Server sent more data than expected")
                        }

                        output.write(buffer, 0, bytesRead)

                        receivedBytes += bytesRead
                        downloadedBytes += bytesRead

                        val total = expectedTotalBytes
                        if (total != null && total > 0L) {
                            val progress =
                                downloadedBytes.toDouble() / total
                            val downloadedMB =
                                downloadedBytes / (1024 * 1024)
                            val totalMB = total / (1024 * 1024)

                            onProgress(
                                progress,
                                "Downloading $distroName: ${downloadedMB}MB / ${totalMB}MB"
                            )
                        }
                    }
                }
            }

            if (
                expectedResponseBytes != null &&
                receivedBytes != expectedResponseBytes
            ) {
                rejectDownload("Received data size does not match expected response size")
            }

            if (
                expectedTotalBytes != null &&
                downloadedBytes != expectedTotalBytes
            ) {
                rejectDownload("Total download size does not match Content-Range")
            }
        } finally {
            connection.disconnect()
        }
    }

    // ── Extraction ──

    /**
     * Extract the downloaded rootfs tarball.
     * Uses the system's tar command (available on Android via toybox).
     */
    fun extractRootfs(
        onProgress: (progress: Double, status: String) -> Unit
    ) {
        thread(name = "rootfs-extract") {
            try {
                val distro = getInstalledDistro()
                val tarball = File(downloadDir, "${distro}-rootfs.tar." + (if (distro == "kali") "xz" else "gz"))

                if (!tarball.exists()) {
                    onProgress(-1.0, "Rootfs tarball not found. Download first.")
                    return@thread
                }

                // Clean previous rootfs
                if (rootfsDir.exists()) {
                    rootfsDir.deleteRecursively()
                }
                rootfsDir.mkdirs()

                onProgress(0.1, "Extracting ${DISTRO_NAMES[distro]}...")
                Log.i(TAG, "Extracting rootfs from ${tarball.absolutePath}")

                // Use ProcessBuilder to run tar extraction
                // Android's toybox includes tar, and we can use xz if available
                val ext = if (distro == "kali") "xz" else "gz"
                val tarFlags = if (ext == "xz") "Jxf" else "zxf"
                val process = ProcessBuilder(
                    "tar", tarFlags, tarball.absolutePath,
                    "-C", rootfsDir.absolutePath
                )
                    .redirectErrorStream(true)
                    .start()

                // Read output for progress indication
                val reader = process.inputStream.bufferedReader()
                var line: String?
                var lineCount = 0
                var lastLine = ""
                while (reader.readLine().also { line = it } != null) {
                    lastLine = line!!
                    if (lineCount % 500 == 0) {
                        onProgress(0.1 + (lineCount % 5000) / 10000.0, "Extracting: $line")
                    }
                    lineCount++
                }

                val exitCode = process.waitFor()
                val binDir = File(rootfsDir, "bin")
                
                // Android's tar will fail (code 1 or 2) when trying to chown files to root or create /dev nodes.
                // We ignore this as long as the core filesystem extracted successfully.
                                if (exitCode != 0) {
                    val hasCoreFilesystem =
                        File(rootfsDir, "bin").let { it.exists() && it.list()?.isNotEmpty() == true } &&
                        File(rootfsDir, "usr").isDirectory &&
                        File(rootfsDir, "etc").isDirectory

                    if (!hasCoreFilesystem) {
                        throw RuntimeException("tar failed (code $exitCode): $lastLine")
                    }

                    Log.w(TAG, "tar reported extraction warnings; core directories exist")
                }

                onProgress(0.7, "Configuring Linux environment...")

                // Post-extraction configuration
                configureRootfs()

                // Mark setup as completely successful
                File(context.filesDir, "SETUP_COMPLETE").writeText("done")

                // Clean up tarball to save space
                tarball.delete()

                onProgress(1.0, "${DISTRO_NAMES[distro] ?: distro} setup complete")
                Log.i(TAG, "Rootfs extraction complete. Size: ${getRootfsSizeMB()} MB")

            } catch (e: Exception) {
                Log.e(TAG, "Extraction failed: ${e.message}", e)
                onProgress(-1.0, "Extraction failed: ${e.message}")
            }
        }
    }

    // ── Post-install Configuration ──
    /**
     * Configure the extracted rootfs with essential settings.
     * Sets up user, sudo, apt sources, DNS, and environment.
     */
    private fun configureRootfs() {
        Log.i(TAG, "Configuring rootfs...")

        // DNS resolution
        File(rootfsDir, "etc/resolv.conf").apply {
            parentFile?.mkdirs()
            writeText("""
                nameserver 8.8.8.8
                nameserver 8.8.4.4
                nameserver 1.1.1.1
            """.trimIndent())
        }

        // Disable apt sandbox (CRITICAL for Android)
        // If apt drops to the _apt user, it loses the Android 'inet' group and hangs indefinitely without network access.
        val aptConfDir = File(rootfsDir, "etc/apt/apt.conf.d")
        aptConfDir.mkdirs()
        File(aptConfDir, "99-disable-sandbox").writeText("APT::Sandbox::User \"root\";\n")

        // Hostname
        File(rootfsDir, "etc/hostname").writeText("droiddesk\n")

        // Hosts file
        File(rootfsDir, "etc/hosts").apply {
            parentFile?.mkdirs()
            writeText("""
                127.0.0.1   localhost
                127.0.0.1   droiddesk
                ::1         localhost ip6-localhost ip6-loopback
            """.trimIndent())
        }

        // Environment variables for the Linux session
        File(rootfsDir, "etc/profile.d/droiddesk.sh").apply {
            parentFile?.mkdirs()
            writeText("""
                #!/bin/bash
                # DroidDesk environment configuration
                export DISPLAY=:0
                export PULSE_SERVER=127.0.0.1
                export MESA_NO_ERROR=1
                export MESA_GL_VERSION_OVERRIDE=4.6
                export MESA_GLES_VERSION_OVERRIDE=3.2
                export GALLIUM_DRIVER=zink
                export MESA_LOADER_DRIVER_OVERRIDE=zink
                export TU_DEBUG=noconform
                export ZINK_DESCRIPTORS=lazy
                export MESA_VK_WSI_PRESENT_MODE=immediate
                
                # XDG directories
                export XDG_RUNTIME_DIR=/tmp/runtime-root
                mkdir -p "${'$'}XDG_RUNTIME_DIR" 2>/dev/null
                
                # Color prompt
                export PS1='\[\033[01;32m\]droiddesk\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
                
                alias ll='ls -la --color=auto'
                alias update='apt update && apt upgrade -y'
            """.trimIndent())
        }

        // Sudo configuration (passwordless for root)
        File(rootfsDir, "etc/sudoers.d/droiddesk").apply {
            parentFile?.mkdirs()
            writeText("""
                Defaults !requiretty
                root ALL=(ALL) NOPASSWD: ALL
            """.trimIndent())
        }

        // Create required directories
        listOf(
            "tmp",
            "tmp/runtime-root",
            "run",
            "var/run",
            "dev/shm"
        ).forEach {
            File(rootfsDir, it).mkdirs()
        }

        Log.i(TAG, "Rootfs configuration complete")
    }

    // ── Desktop Environment Installation ──

    /**
     * Install a desktop environment inside the rootfs using apt.
     * Called after rootfs extraction.
     */
    fun installDesktopEnvironment(
        de: String,
        runtime: LinuxRuntime,
        onProgress: (Double, String) -> Unit,
        onLog: (String) -> Unit
    ) {
        thread(name = "de-install") {
            try {
                // Forcefully release any stuck apt locks before starting
                onProgress(0.0, "Clearing package manager locks...")
                try {
                    runtime.executeCommand("""
                        killall -9 apt apt-get dpkg 2>/dev/null || true
                        rm -f /var/lib/apt/lists/lock
                        rm -f /var/cache/apt/archives/lock
                        rm -f /var/lib/dpkg/lock*
                        dpkg --configure -a
                    """.trimIndent(), onLog)
                } catch (e: Exception) {
                    Log.w(TAG, "Lock clearing failed, continuing anyway: ${e.message}")
                }
                
                onProgress(0.0, "Updating package lists...")
                runtime.executeCommand("apt-get update -y", onLog)
                
                // Pre-configure Firefox PPA to fix Ubuntu snap issue
                onProgress(0.1, "Configuring repositories...")
                runtime.executeCommand("""
                    DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get install -y software-properties-common wget gpg
                    add-apt-repository ppa:mozillateam/ppa -y
                    echo "Package: *" > /etc/apt/preferences.d/mozilla-firefox
                    echo "Pin: release o=LP-PPA-mozillateam" >> /etc/apt/preferences.d/mozilla-firefox
                    echo "Pin-Priority: 1001" >> /etc/apt/preferences.d/mozilla-firefox
                    
                    # Add Microsoft repository for VS Code
                    mkdir -p /etc/apt/keyrings
                    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
                    install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
                    echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list
                    rm -f packages.microsoft.gpg
                    
                    apt-get update -y
                """.trimIndent(), onLog)

                var packages = when (de) {
                    "xfce4" -> "xfce4 xfce4-terminal xfce4-whiskermenu-plugin thunar mousepad devilspie2 dbus-x11 xclip"
                    "lxqt" -> "lxqt qterminal pcmanfm-qt featherpad dbus-x11"
                    "mate" -> "mate-desktop-environment mate-terminal dbus-x11"
                    "kde" -> "plasma-desktop konsole dolphin dbus-x11"
                    else -> "xfce4 xfce4-terminal dbus-x11"
                }
                
                // Fix broken dependencies from interrupted apt installs
                runtime.executeCommand("DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get install -f -y", onLog)

                onProgress(0.2, "Installing $de packages...")
                runtime.executeCommand(
                    "DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get install -y --no-install-recommends $packages", onLog
                )

                onProgress(0.8, "Installing core utilities...")
                val result = runtime.executeCommand(
                    "DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get install -y --no-install-recommends " +
                    "git wget curl python3 python3-pip htop nano sudo libgl1 x11-xserver-utils", onLog
                )

                onProgress(0.9, "Configuring embedded X11 display...")
                
                if (result.contains("E: ")) {
                    throw Exception("Apt-get failed: Check terminal output.")
                }

                deConfigFile.writeText(de)
                onProgress(1.0, "$de installation complete!")

            } catch (e: Exception) {
                Log.e(TAG, "DE installation failed: ${e.message}", e)
                onProgress(-1.0, "Installation failed: ${e.message}")
            }
        }
    }

    // ── Utility ──

    private fun calculateDirSize(dir: File): Long {
        if (!dir.exists()) return 0
        return dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
    }
}
