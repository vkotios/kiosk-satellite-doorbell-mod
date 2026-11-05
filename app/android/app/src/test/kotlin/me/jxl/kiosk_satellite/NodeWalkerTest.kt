package me.jxl.kiosk_satellite

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class NodeWalkerTest {
    private class FakeNode(
        override val text: String? = null,
        override val description: String? = null,
        override val clickable: Boolean = false,
    ) : ClickNode {
        override var parent: ClickNode? = null
        private val childNodes = ArrayList<FakeNode>()
        override val children: List<ClickNode> get() = childNodes

        fun add(child: FakeNode) {
            child.parent = this
            childNodes.add(child)
        }
    }

    /** A clickable camera card holding a thumbnail, the doorbell text, the wifi level and the "99+" badge. */
    private fun cameraCard(doorbellText: String): FakeNode {
        val card = FakeNode(clickable = true)
        card.add(FakeNode(description = "thumbnail"))
        card.add(FakeNode(text = doorbellText))
        card.add(FakeNode(description = "Wifi Signal Level"))
        card.add(FakeNode(text = "99+"))
        return card
    }

    /** The Eufy home screen: a root (not clickable) holding a tab row ("Favorites",
     *  "Security"), the Back and Front camera cards, and a bottom bar ("Home", "Events"). */
    private fun homeScreen(): FakeNode {
        val root = FakeNode()
        val tabRow = FakeNode()
        tabRow.add(FakeNode(text = "Favorites", clickable = true))
        tabRow.add(FakeNode(text = "Security", clickable = true))
        root.add(tabRow)
        root.add(cameraCard("Doorbell Back Door"))
        root.add(cameraCard("Doorbell Front Door"))
        val bottomBar = FakeNode()
        bottomBar.add(FakeNode(text = "Home", clickable = true))
        bottomBar.add(FakeNode(text = "Events", clickable = true))
        root.add(bottomBar)
        return root
    }

    /** The Back camera card of a home screen root: the child after the tab row. */
    private fun backCard(root: ClickNode): ClickNode = root.children[1]

    /** The Front camera card of a home screen root: the child after the Back card. */
    private fun frontCard(root: ClickNode): ClickNode = root.children[2]

    /** A chain with the label node [steps] parent steps below a clickable
     *  top, so the clickable ancestor is exactly [steps] steps above the match. */
    private fun chainToClickable(steps: Int): FakeNode {
        val root = FakeNode(clickable = true)
        var node = root
        repeat(steps - 1) {
            val child = FakeNode()
            node.add(child)
            node = child
        }
        node.add(FakeNode(text = "Doorbell Front Door"))
        return root
    }

    @Test fun findClickTargetReturnsTheCardHoldingTheExactDoorbellText() {
        val root = homeScreen()
        // The text node inside the card is not clickable, so its nearest clickable ancestor, the card, is returned.
        assertSame(frontCard(root), NodeWalker.findClickTarget(root, "Doorbell Front Door"))
    }

    @Test fun findClickTargetMatchesIgnoringCaseAndSpacing() {
        val root = homeScreen()
        assertSame(frontCard(root), NodeWalker.findClickTarget(root, "  doorbell   front door "))
    }

    @Test fun findClickTargetReturnsTheBackCardForItsOwnDoorbellText() {
        val root = homeScreen()
        assertSame(backCard(root), NodeWalker.findClickTarget(root, "Doorbell Back Door"))
    }

    @Test fun findClickTargetUsesTheUniqueContainingNodeWhenNothingMatchesExactly() {
        val root = homeScreen()
        assertSame(frontCard(root), NodeWalker.findClickTarget(root, "Front Door"))
    }

    @Test fun findClickTargetReturnsNullWhenTwoNodesContainTheLabel() {
        val root = homeScreen()
        assertNull(NodeWalker.findClickTarget(root, "Door"))
    }

    @Test fun findClickTargetReturnsNullForALabelNoNodeCarries() {
        val root = homeScreen()
        assertNull(NodeWalker.findClickTarget(root, "Nonexistent"))
    }

    @Test fun findClickTargetReturnsNullForABlankLabel() {
        val root = homeScreen()
        assertNull(NodeWalker.findClickTarget(root, ""))
        assertNull(NodeWalker.findClickTarget(root, "   "))
    }

    @Test fun findClickTargetReturnsNullWhenTheMatchHasNoClickableAncestor() {
        val root = FakeNode()
        root.add(FakeNode(text = "Doorbell Front Door"))
        assertNull(NodeWalker.findClickTarget(root, "Doorbell Front Door"))
    }

    @Test fun findClickTargetReturnsAMatchingNodeThatIsItselfClickable() {
        val root = homeScreen()
        val favoritesTab = root.children[0].children[0]
        assertSame(favoritesTab, NodeWalker.findClickTarget(root, "Favorites"))
    }

    @Test fun findClickTargetMatchesByDescriptionWhenTheTextIsEmpty() {
        val root = FakeNode()
        val card = FakeNode(clickable = true)
        root.add(card)
        card.add(FakeNode(description = "Doorbell Side Door"))
        assertSame(card, NodeWalker.findClickTarget(root, "Doorbell Side Door"))
    }

    @Test fun findClickTargetPrefersAnExactMatchOverAnEarlierContainingNode() {
        val root = FakeNode()
        val containing = FakeNode(text = "Doorbell Front Door and more", clickable = true)
        val exact = FakeNode(text = "Doorbell Front Door", clickable = true)
        root.add(containing)
        root.add(exact)
        // Pass 1 wins: the exact match is returned even though the containing node comes first in document order.
        assertSame(exact, NodeWalker.findClickTarget(root, "Doorbell Front Door"))
    }

    @Test fun findClickTargetReturnsTheFirstExactMatchInDocumentOrder() {
        val root = FakeNode()
        val first = FakeNode(text = "Doorbell Front Door", clickable = true)
        val nested = FakeNode(text = "Doorbell Front Door", clickable = true)
        val second = FakeNode(text = "Doorbell Front Door", clickable = true)
        root.add(first)
        first.add(nested)
        root.add(second)
        // Document order is first, its child, then second; the first wins.
        assertSame(first, NodeWalker.findClickTarget(root, "Doorbell Front Door"))
    }

    @Test fun findClickTargetMatchesTheWifiLabelAndClicksItsCard() {
        val root = homeScreen()
        // Matching is by label only: the first node described "Wifi Signal Level" lives in the Back card.
        assertSame(backCard(root), NodeWalker.findClickTarget(root, "Wifi Signal Level"))
    }

    @Test fun findClickTargetStopsDescendingAtDepthForty() {
        // The walk stops descending at depth 40, so the label node 100 levels down is never visited: no crash, no target.
        val root = FakeNode()
        var node = root
        repeat(99) {
            val child = FakeNode()
            node.add(child)
            node = child
        }
        node.add(FakeNode(text = "Doorbell Front Door", clickable = true))
        assertNull(NodeWalker.findClickTarget(root, "Doorbell Front Door"))
    }

    @Test fun findClickTargetReturnsTheSecondExactMatchWhenTheFirstHasNoClickTarget() {
        val root = FakeNode()
        val bare = FakeNode(text = "Doorbell Front Door")
        val card = FakeNode(clickable = true)
        val second = FakeNode(text = "Doorbell Front Door")
        root.add(bare)
        root.add(card)
        card.add(second)
        // The first exact match has no clickable ancestor, so the second one is tried.
        assertSame(card, NodeWalker.findClickTarget(root, "Doorbell Front Door"))
    }

    @Test fun findClickTargetFindsAClickableAncestorTwelveStepsUpButNotThirteen() {
        // MAX_PARENT_STEPS is 12: a clickable top exactly 12 parent steps above the match is found, one 13 above is not.
        val near = chainToClickable(12)
        assertSame(near, NodeWalker.findClickTarget(near, "Doorbell Front Door"))
        val far = chainToClickable(13)
        assertNull(NodeWalker.findClickTarget(far, "Doorbell Front Door"))
    }

    @Test fun findClickTargetDoesNotMatchByDescriptionWhenTheTextIsNotBlank() {
        // hasNoText is "the text is null or blank": a node with non-blank text never matches by description.
        val root = FakeNode()
        val card = FakeNode(clickable = true)
        root.add(card)
        card.add(FakeNode(text = "Battery 84%", description = "Doorbell Front Door"))
        assertNull(NodeWalker.findClickTarget(root, "Doorbell Front Door"))
    }

    @Test fun findClickTargetReturnsNullWhenTheExactMatchHasNoTargetAndTwoNodesContain() {
        val root = FakeNode()
        root.add(FakeNode(text = "Doorbell Front Door"))
        root.add(FakeNode(text = "Doorbell Front Door and more", clickable = true))
        // The exact match has no clickable ancestor and two nodes contain the label, so the pass is ambiguous.
        assertNull(NodeWalker.findClickTarget(root, "Doorbell Front Door"))
    }

    @Test fun textsUnderReturnsOnlyTheTextAttributesInDocumentOrder() {
        val root = homeScreen()
        assertEquals(listOf("Doorbell Front Door", "99+"), NodeWalker.textsUnder(frontCard(root)))
    }

    @Test fun textsUnderFallsBackToDescriptionsWhenNoNodeHasText() {
        val root = FakeNode()
        root.add(FakeNode(description = "thumbnail"))
        root.add(FakeNode(description = "Wifi Signal Level"))
        assertEquals(listOf("thumbnail", "Wifi Signal Level"), NodeWalker.textsUnder(root))
    }

    @Test fun textsUnderStopsAtTwentyTexts() {
        val root = FakeNode()
        for (index in 1..25) root.add(FakeNode(text = "Item $index"))
        assertEquals((1..20).map { "Item $it" }, NodeWalker.textsUnder(root))
    }

    @Test fun capturedTextsReturnsTheTextsUnderTheClickedNode() {
        val root = homeScreen()
        val doorbellText = frontCard(root).children[1]
        assertEquals(listOf("Doorbell Front Door"), NodeWalker.capturedTexts(doorbellText))
    }

    @Test fun capturedTextsWalksUpToTheParentWhenTheClickedNodeHasNoText() {
        val card = FakeNode(clickable = true)
        card.add(FakeNode(text = "Doorbell Front Door"))
        card.add(FakeNode(text = "99+"))
        val clicked = FakeNode()
        card.add(clicked)
        // An ImageView-like node: nothing readable on it or under it, so the parent level supplies the texts.
        assertEquals(listOf("Doorbell Front Door", "99+"), NodeWalker.capturedTexts(clicked))
    }

    @Test fun capturedTextsWalksUpToTheGrandParent() {
        val card = FakeNode(clickable = true)
        card.add(FakeNode(text = "Doorbell Front Door"))
        val wrapper = FakeNode()
        card.add(wrapper)
        val clicked = FakeNode()
        wrapper.add(clicked)
        assertEquals(listOf("Doorbell Front Door"), NodeWalker.capturedTexts(clicked))
    }

    @Test fun capturedTextsStopsAfterThreeLevels() {
        // The only text sits on the great-grandparent, a fourth level up, so nothing is captured.
        val greatGrandParent = FakeNode(text = "Doorbell Front Door")
        val grandParent = FakeNode()
        greatGrandParent.add(grandParent)
        val parent = FakeNode()
        grandParent.add(parent)
        val clicked = FakeNode()
        parent.add(clicked)
        assertEquals(emptyList<String>(), NodeWalker.capturedTexts(clicked))
    }

    @Test fun capturedTextsReturnsAnEmptyListWhenNothingIsFound() {
        assertEquals(emptyList<String>(), NodeWalker.capturedTexts(FakeNode()))
    }
}
