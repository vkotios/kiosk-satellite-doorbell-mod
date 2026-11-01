package me.jxl.kiosk_satellite

/** A saved doorbell: the app, and the notification channel whose posts are its rings. */
data class DoorbellSignature(val id: String, val label: String, val pkg: String, val channelPrefix: String)

object DoorbellMatcher {
    /** One segment that channelPrefixOf may drop: the word raw, or a
     *  hexadecimal number with an optional leading minus. */
    private val strippableSegment = Regex("^(raw|-?[0-9a-f]+)$")

    /** The first signature (in list order) whose pkg equals [pkg] and whose
     *  non-blank channelPrefix is a prefix of [channelId]; null when none, or
     *  when channelId is null. Comparison is case-sensitive. */
    fun match(signatures: List<DoorbellSignature>, pkg: String, channelId: String?): DoorbellSignature? {
        if (channelId == null) return null
        return signatures.firstOrNull { signature ->
            signature.pkg == pkg &&
                signature.channelPrefix.isNotBlank() &&
                channelId.startsWith(signature.channelPrefix)
        }
    }

    /** The channel id with its trailing dot-separated segments removed while
     *  each one is the word raw, or a hexadecimal number with an optional
     *  leading minus (lowercase a-f and 0-9 only), i.e. each fully matches the
     *  regex ^(raw|-?[0-9a-f]+)$. Segments are removed from the end and the
     *  removal stops at the first segment that does not match. At least the
     *  first segment is always kept. The empty string stays empty. */
    fun channelPrefixOf(channelId: String): String {
        if (channelId.isEmpty()) return channelId
        val segments = channelId.split('.')
        var kept = segments.size
        while (kept > 1 && strippableSegment.matches(segments[kept - 1])) kept--
        return segments.subList(0, kept).joinToString(".")
    }
}
