package com.orailnoor.droiddesk.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ArchivePathValidatorTest {
    @Test
    fun stripsLeadingParentComponentsFromRootfsEntry() {
        assertEquals(
            "usr/bin/bash",
            ArchivePathValidator.normalizeEntryName("../.././usr/bin/bash"),
        )
    }

    @Test
    fun normalizesDotAndInternalParentComponents() {
        assertEquals(
            "usr/lib/example.so",
            ArchivePathValidator.normalizeEntryName("./usr/bin/../lib/example.so"),
        )
    }

    @Test
    fun rejectsTraversalThatWouldEscapeTheRoot() {
        assertThrows(SecurityException::class.java) {
            ArchivePathValidator.normalizeEntryName("usr/lib/../../../../data/passwd")
        }
    }

    @Test
    fun rejectsAbsoluteAndWindowsDrivePaths() {
        assertThrows(SecurityException::class.java) {
            ArchivePathValidator.normalizeEntryName("/etc/passwd")
        }
        assertThrows(SecurityException::class.java) {
            ArchivePathValidator.normalizeEntryName("C:/Windows/system.ini")
        }
    }

    @Test
    fun acceptsRelativeSymlinkThatStaysInsideRoot() {
        assertEquals(
            "../lib",
            ArchivePathValidator.validateSymbolicLinkTarget("usr/bin/tool", "../lib"),
        )
    }

    @Test
    fun rejectsRelativeSymlinkThatEscapesRoot() {
        assertThrows(SecurityException::class.java) {
            ArchivePathValidator.validateSymbolicLinkTarget("usr/bin/tool", "../../../../data")
        }
    }
}
