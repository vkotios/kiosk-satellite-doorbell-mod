package me.jxl.kiosk_satellite

import java.util.Locale

object LabelMatcher {
    /** A run of whitespace, which normalize collapses to one space. */
    private val whitespaceRun = Regex("\\s+")

    /** Lower-cased (Locale.ROOT), trimmed, every run of whitespace collapsed to
     *  one space; null becomes "". */
    fun normalize(s: String?): String {
        if (s == null) return ""
        return s.trim().replace(whitespaceRun, " ").lowercase(Locale.ROOT)
    }

    /** True when [label] is not blank and normalize(candidate) equals normalize(label). */
    fun matches(candidate: String?, label: String): Boolean {
        val normalizedLabel = normalize(label)
        if (normalizedLabel.isBlank()) return false
        return normalize(candidate) == normalizedLabel
    }

    /** True when [label] is not blank and normalize(candidate) contains normalize(label). */
    fun contains(candidate: String?, label: String): Boolean {
        val normalizedLabel = normalize(label)
        if (normalizedLabel.isBlank()) return false
        return normalize(candidate).contains(normalizedLabel)
    }

    /** The text the teach step offers for a clicked card: the first of [texts]
     *  (in the order given) that, normalized, has at least 3 characters and
     *  contains at least one letter (Char.isLetter); null when none. Digits-only
     *  text like "99+" or "12:30" never qualifies. Returns the original text
     *  trimmed (not lower-cased). */
    fun bestLabel(texts: List<String>): String? {
        for (text in texts) {
            val trimmed = text.trim()
            val normalized = normalize(trimmed)
            if (normalized.length >= 3 && normalized.any { it.isLetter() }) return trimmed
        }
        return null
    }
}
