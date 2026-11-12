package me.jxl.kiosk_satellite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LabelMatcherTest {
    @Test fun normalizeLowerCasesTrimsAndCollapsesWhitespace() {
        assertEquals("doorbell front door", LabelMatcher.normalize("Doorbell Front Door"))
        assertEquals("doorbell", LabelMatcher.normalize("  Doorbell  "))
        assertEquals("doorbell front door", LabelMatcher.normalize("  Doorbell \t Front   Door  "))
    }

    @Test fun normalizeTurnsNullIntoTheEmptyString() {
        assertEquals("", LabelMatcher.normalize(null))
    }

    @Test fun matchesIsTrueForEqualTextIgnoringCaseAndSpacing() {
        assertTrue(LabelMatcher.matches("Doorbell Front Door", "doorbell front door"))
        assertTrue(LabelMatcher.matches("  DOORBELL   Front Door ", "Doorbell Front Door"))
    }

    @Test fun matchesIsFalseForDifferentText() {
        assertFalse(LabelMatcher.matches("Doorbell Back Door", "Doorbell Front Door"))
    }

    @Test fun matchesNeverMatchesABlankLabel() {
        assertFalse(LabelMatcher.matches("Doorbell", ""))
        assertFalse(LabelMatcher.matches("   ", "   "))
    }

    @Test fun matchesIsFalseForANullCandidate() {
        assertFalse(LabelMatcher.matches(null, "Doorbell"))
    }

    @Test fun containsIsTrueForASubstringIgnoringCaseAndSpacing() {
        assertTrue(LabelMatcher.contains("Doorbell Front Door", "Front"))
        assertTrue(LabelMatcher.contains("  Doorbell Front Door ", "front door"))
    }

    @Test fun containsIsFalseWhenTheTextDoesNotContainTheLabel() {
        assertFalse(LabelMatcher.contains("Doorbell Front Door", "Back"))
    }

    @Test fun containsNeverMatchesABlankLabel() {
        assertFalse(LabelMatcher.contains("Doorbell Front Door", ""))
        assertFalse(LabelMatcher.contains("Doorbell Front Door", "   "))
    }

    @Test fun bestLabelReturnsTheFirstQualifyingTextInTheOrderGiven() {
        // "99+" has no letter and "Wifi" comes later, so "Doorbell Front Door" wins.
        assertEquals("Doorbell Front Door", LabelMatcher.bestLabel(listOf("99+", "Doorbell Front Door", "Wifi")))
    }

    @Test fun bestLabelReturnsNullWhenNoTextQualifies() {
        assertNull(LabelMatcher.bestLabel(listOf("ab", "x")))
        assertNull(LabelMatcher.bestLabel(listOf("12:30", "5")))
    }

    @Test fun bestLabelTrimsTheAnswerButKeepsItsCase() {
        assertEquals("Front Door", LabelMatcher.bestLabel(listOf("  Front Door  ")))
    }
}
