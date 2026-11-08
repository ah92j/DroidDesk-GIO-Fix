package com.orailnoor.droiddesk.runtime

import java.nio.charset.StandardCharsets

/**
 * Normalizes member paths from official Linux rootfs archives.
 *
 * Leading ../ components are stripped like GNU tar does when extracting an
 * archive without --absolute-names. Parent components inside a path are
 * resolved lexically. Any attempt to move above the extraction root is rejected.
 */
internal object ArchivePathValidator {
    private const val MAX_COMPONENT_BYTES = 255
    private const val MAX_PATH_BYTES = 4096

    fun normalizeEntryName(rawName: String, stripLeadingParents: Boolean = true): String {
        val name = rawName.removeSuffix("\r")
        if (name.isEmpty()) return ""

        if (
            name.startsWith("/") ||
            Regex("^[A-Za-z]:").containsMatchIn(name) ||
            name.contains('\\') ||
            name.any { it.isISOControl() }
        ) {
            throw SecurityException("Blocked unsafe archive path: ${display(name)}")
        }

        val components = ArrayList<String>()
        var hasSeenNormalComponent = false

        for (component in name.split('/')) {
            when (component) {
                "", "." -> Unit
                ".." -> {
                    if (components.isNotEmpty()) {
                        components.removeAt(components.lastIndex)
                    } else if (stripLeadingParents && !hasSeenNormalComponent) {
                        // Match the safe default behavior of tar: strip leading
                        // parent traversals instead of resolving outside the root.
                        continue
                    } else {
                        throw SecurityException("Blocked archive path traversal: ${display(name)}")
                    }
                }
                else -> {
                    if (component.toByteArray(StandardCharsets.UTF_8).size > MAX_COMPONENT_BYTES) {
                        throw SecurityException("Archive path component is too long: ${display(name)}")
                    }
                    components.add(component)
                    hasSeenNormalComponent = true
                }
            }
        }

        val normalized = components.joinToString("/")
        if (normalized.toByteArray(StandardCharsets.UTF_8).size > MAX_PATH_BYTES) {
            throw SecurityException("Archive path is too long: ${display(name)}")
        }
        return normalized
    }

    /**
     * Validate a symbolic-link target relative to the link's containing folder.
     * Absolute links are treated as guest-root paths (normal Linux rootfs layout).
     */
    fun validateSymbolicLinkTarget(entryName: String, rawTarget: String): String {
        val target = rawTarget.removeSuffix("\r")
        if (
            target.isEmpty() ||
            target.contains('\\') ||
            target.any { it.isISOControl() } ||
            Regex("^[A-Za-z]:").containsMatchIn(target)
        ) {
            throw SecurityException("Blocked unsafe symbolic-link target: ${display(target)}")
        }

        if (target.startsWith("/")) {
            val guestPath = target.removePrefix("/")
            normalizeEntryName(guestPath, stripLeadingParents = false)
            return target
        }

        val parent = entryName.substringBeforeLast('/', "")
        val combined = if (parent.isEmpty()) target else "$parent/$target"
        normalizeEntryName(combined, stripLeadingParents = false)
        return target
    }

    private fun display(value: String): String =
        value.replace("\n", "\\n").replace("\t", "\\t").take(240)
}
