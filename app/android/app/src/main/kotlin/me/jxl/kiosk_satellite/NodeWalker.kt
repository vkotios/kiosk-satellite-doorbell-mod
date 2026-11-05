package me.jxl.kiosk_satellite

/** The part of an accessibility node the click needs, so the walk is testable without Android. */
interface ClickNode {
    val text: String?
    val description: String?
    val clickable: Boolean
    val children: List<ClickNode>
    val parent: ClickNode?
}

object NodeWalker {
    /** The walk stops descending at this depth (the root is depth 0), so a very
     *  deep or cyclic tree cannot overflow the stack. */
    private const val MAX_DEPTH = 40

    /** How many parent links the walk may follow up from a matched node. */
    private const val MAX_PARENT_STEPS = 12

    /** How many texts textsUnder returns at most. */
    private const val MAX_TEXTS = 20

    /** How many levels capturedTexts looks at: the clicked node, its parent, then its grandparent. */
    private const val MAX_CAPTURE_LEVELS = 3

    /** The node to click for [label], or null.
     *  Pass 1: the exact matches in document order (depth first, children
     *  in list order, the node before its children) are tried one by one,
     *  and the first with a click target wins; a node whose text is empty
     *  may match by description in the same pass (text is tried before
     *  description on each node). An exact match without a click target
     *  does not end the search.
     *  Pass 2, only when no exact match has a click target: if exactly
     *  one node (by text, then description) contains the label
     *  (LabelMatcher.contains), that node; two or more means ambiguous,
     *  so null.
     *  The matched node is returned as its click target: itself when
     *  clickable, else its nearest clickable ancestor (walk parent
     *  links, at most 12 steps); null when there is none. A blank label
     *  returns null. Never returns a node that was not matched or an
     *  ancestor of one.
     *  The walk stops descending at depth 40. */
    fun findClickTarget(root: ClickNode, label: String): ClickNode? {
        if (LabelMatcher.normalize(label).isBlank()) return null
        val nodes = documentOrder(root)
        for (node in nodes) {
            if (!matchesExactly(node, label)) continue
            val target = clickTargetOf(node)
            if (target != null) return target
        }
        val containing = nodes.filter { node -> matchesContaining(node, label) }
        if (containing.size == 1) return clickTargetOf(containing[0])
        return null
    }

    /** The non-blank, trimmed texts (text attribute only) of [node] and its
     *  descendants in document order, at most 20. When none has text, the same
     *  walk over descriptions instead. */
    fun textsUnder(node: ClickNode): List<String> {
        val nodes = documentOrder(node)
        val texts = readableValues(nodes) { it.text }
        if (texts.isNotEmpty()) return texts
        return readableValues(nodes) { it.description }
    }

    /** For a node the user clicked: textsUnder(node); when that is empty,
     *  textsUnder(node.parent); then the grandparent; at most 3 levels up.
     *  Empty list when nothing is found. */
    fun capturedTexts(clicked: ClickNode): List<String> {
        var node: ClickNode? = clicked
        var levels = 0
        while (node != null && levels < MAX_CAPTURE_LEVELS) {
            val texts = textsUnder(node)
            if (texts.isNotEmpty()) return texts
            node = node.parent
            levels++
        }
        return emptyList()
    }

    /** [root] and its descendants in document order: the node before its
     *  children, children in list order. The walk stops descending at depth 40
     *  (the root is depth 0), so a very deep or cyclic tree cannot overflow the
     *  stack. */
    private fun documentOrder(root: ClickNode): List<ClickNode> {
        val nodes = ArrayList<ClickNode>()
        val pending = ArrayDeque<Pair<ClickNode, Int>>()
        pending.addLast(root to 0)
        while (pending.isNotEmpty()) {
            val (node, depth) = pending.removeLast()
            nodes.add(node)
            if (depth + 1 < MAX_DEPTH) {
                for (child in node.children.asReversed()) pending.addLast(child to depth + 1)
            }
        }
        return nodes
    }

    /** Whether [node] carries [label] exactly: on its text, or on its
     *  description when its text is empty. */
    private fun matchesExactly(node: ClickNode, label: String): Boolean =
        LabelMatcher.matches(node.text, label) ||
            (hasNoText(node) && LabelMatcher.matches(node.description, label))

    /** Whether [node] contains [label]: on its text, or on its description when
     *  its text is empty. */
    private fun matchesContaining(node: ClickNode, label: String): Boolean =
        LabelMatcher.contains(node.text, label) ||
            (hasNoText(node) && LabelMatcher.contains(node.description, label))

    /** Whether [node]'s text is null or blank, so its description may be matched. */
    private fun hasNoText(node: ClickNode): Boolean = LabelMatcher.normalize(node.text).isEmpty()

    /** The click target for a matched [node]: itself when clickable, else its
     *  nearest clickable ancestor within 12 parent steps; null when there is none. */
    private fun clickTargetOf(node: ClickNode): ClickNode? {
        if (node.clickable) return node
        var ancestor = node.parent
        var steps = 0
        while (ancestor != null && steps < MAX_PARENT_STEPS) {
            if (ancestor.clickable) return ancestor
            ancestor = ancestor.parent
            steps++
        }
        return null
    }

    /** The non-blank, trimmed [select] values over [nodes], in order, at most 20. */
    private fun readableValues(nodes: List<ClickNode>, select: (ClickNode) -> String?): List<String> {
        val values = ArrayList<String>()
        for (node in nodes) {
            val value = select(node)?.trim()
            if (value != null && value.isNotBlank()) values.add(value)
            if (values.size == MAX_TEXTS) break
        }
        return values
    }
}
