package me.jxl.kiosk_satellite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class DoorbellMatcherTest {
    private fun doorbell(id: String, pkg: String, channelPrefix: String) =
        DoorbellSignature(id, "Front door", pkg, channelPrefix)

    @Test fun channelPrefixOfStripsTrailingRawAndHexSegments() {
        assertEquals(
            "com.ocean.battery.cam.ring",
            DoorbellMatcher.channelPrefixOf("com.ocean.battery.cam.ring.raw.2131951628"),
        )
        assertEquals(
            "com.ocean.battery.cam.ring",
            DoorbellMatcher.channelPrefixOf("com.ocean.battery.cam.ring.-4b3c974b"),
        )
        assertEquals(
            "com.ocean.battery.cam.motion",
            DoorbellMatcher.channelPrefixOf("com.ocean.battery.cam.motion.raw.-1"),
        )
    }

    @Test fun channelPrefixOfChangesNothingWhenNoTrailingSegmentStrips() {
        assertEquals(
            "com.ocean.battery.cam.motion.noprompt",
            DoorbellMatcher.channelPrefixOf("com.ocean.battery.cam.motion.noprompt"),
        )
    }

    @Test fun channelPrefixOfAlwaysKeepsASingleSegment() {
        assertEquals("shell_cmd", DoorbellMatcher.channelPrefixOf("shell_cmd"))
        // "71" is a hexadecimal number, but a single segment is always kept.
        assertEquals("71", DoorbellMatcher.channelPrefixOf("71"))
    }

    @Test fun channelPrefixOfKeepsTheEmptyString() {
        assertEquals("", DoorbellMatcher.channelPrefixOf(""))
    }

    @Test fun channelPrefixOfStripsAWordMadeOnlyOfHexLetters() {
        // Known heuristic: a word made only of hex letters, like "cafe",
        // counts as a hexadecimal number, so "app.cafe" loses its last segment.
        assertEquals("app", DoorbellMatcher.channelPrefixOf("app.cafe"))
    }

    @Test fun matchReturnsTheSignatureWhosePackageAndChannelPrefixFit() {
        val signature = doorbell("battery", "com.ocean.battery.cam", "com.ocean.battery.cam.ring")
        assertSame(
            signature,
            DoorbellMatcher.match(listOf(signature), "com.ocean.battery.cam", "com.ocean.battery.cam.ring.raw.2131951628"),
        )
    }

    @Test fun matchReturnsNullWhenTheChannelDoesNotStartWithThePrefix() {
        val signature = doorbell("battery", "com.ocean.battery.cam", "com.ocean.battery.cam.ring")
        assertNull(
            DoorbellMatcher.match(listOf(signature), "com.ocean.battery.cam", "com.ocean.battery.cam.motion.raw.1"),
        )
    }

    @Test fun matchReturnsNullWhenThePackageDiffers() {
        val signature = doorbell("battery", "com.ocean.battery.cam", "com.ocean.battery.cam.ring")
        assertNull(
            DoorbellMatcher.match(listOf(signature), "com.other.app", "com.ocean.battery.cam.ring.raw.1"),
        )
    }

    @Test fun matchReturnsNullWhenTheChannelIdIsNull() {
        val signature = doorbell("battery", "com.ocean.battery.cam", "com.ocean.battery.cam.ring")
        assertNull(DoorbellMatcher.match(listOf(signature), "com.ocean.battery.cam", null))
    }

    @Test fun matchNeverMatchesABlankPrefix() {
        // A blank prefix would otherwise be a prefix of every channel id.
        val emptyPrefix = doorbell("empty", "com.ocean.battery.cam", "")
        val spacePrefix = doorbell("spaces", "com.ocean.battery.cam", "   ")
        assertNull(
            DoorbellMatcher.match(listOf(emptyPrefix), "com.ocean.battery.cam", "com.ocean.battery.cam.ring"),
        )
        assertNull(
            DoorbellMatcher.match(listOf(spacePrefix), "com.ocean.battery.cam", "   com.ocean.battery.cam.ring"),
        )
    }

    @Test fun matchReturnsTheFirstMatchingSignatureInListOrder() {
        val first = doorbell("ring", "com.ocean.battery.cam", "com.ocean.battery.cam.ring")
        val second = doorbell("cam", "com.ocean.battery.cam", "com.ocean.battery.cam")
        assertSame(
            first,
            DoorbellMatcher.match(listOf(first, second), "com.ocean.battery.cam", "com.ocean.battery.cam.ring.raw.1"),
        )
    }

    @Test fun matchReturnsNullForAnEmptyList() {
        assertNull(
            DoorbellMatcher.match(emptyList(), "com.ocean.battery.cam", "com.ocean.battery.cam.ring"),
        )
    }

    @Test fun matchIsCaseSensitive() {
        val signature = doorbell("battery", "com.ocean.battery.cam", "com.ocean.battery.cam.Ring")
        // Neither the prefix nor the package matches when the case differs.
        assertNull(
            DoorbellMatcher.match(listOf(signature), "com.ocean.battery.cam", "com.ocean.battery.cam.ring.raw.1"),
        )
        assertNull(
            DoorbellMatcher.match(listOf(signature), "Com.Ocean.Battery.Cam", "com.ocean.battery.cam.Ring.raw.1"),
        )
    }

    @Test fun matchSkipsANonMatchingSignatureAndReturnsALaterOne() {
        val other = doorbell("other", "com.other.app", "com.ocean.battery.cam.ring")
        val signature = doorbell("battery", "com.ocean.battery.cam", "com.ocean.battery.cam.ring")
        assertSame(
            signature,
            DoorbellMatcher.match(listOf(other, signature), "com.ocean.battery.cam", "com.ocean.battery.cam.ring.raw.1"),
        )
    }

    @Test fun channelPrefixOfOnlyStripsFromTheEnd() {
        // An interior "raw" stays because the last segment "ring" does not match.
        assertEquals(
            "com.raw.ring",
            DoorbellMatcher.channelPrefixOf("com.raw.ring"),
        )
        assertEquals(
            "com.cafe.ring",
            DoorbellMatcher.channelPrefixOf("com.cafe.ring.raw.1"),
        )
    }

    @Test fun channelPrefixOfKeepsTheFirstSegmentWhenEverySegmentMatches() {
        assertEquals("raw", DoorbellMatcher.channelPrefixOf("raw.1"))
        assertEquals("dead", DoorbellMatcher.channelPrefixOf("dead.beef"))
    }

    @Test fun channelPrefixOfKeepsTrailingEmptySegments() {
        // The empty last segment does not match, so nothing is stripped.
        assertEquals("app.raw.", DoorbellMatcher.channelPrefixOf("app.raw."))
        assertEquals("app.", DoorbellMatcher.channelPrefixOf("app..raw"))
    }
}
