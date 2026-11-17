package org.simpleagentmanager.app

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.simpleagentmanager.core.*

/** The session tools that used to open web, rendered from core snapshots. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-420dpi", application = Application::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SessionToolsTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private val now = System.currentTimeMillis()
    private val chat = ChatState(
        projectId = "p", sessionId = "s",
        session = ChatSession(null, null, "owner", true, "s", "Fix login", SessionStatus.ACTIVE, 2u, 0, null, "t", false,
            TaskSummary("t", "failed", null, null, "Tests failed", "sam/fix", null, null)),
        items = listOf(
            ChatItem("u1", 1, ChatContent.User("Please fix the token refresh.", emptyList())),
            ChatItem("a1", 2, ChatContent.Agent("I fixed it and opened PR #42.", emptyList())),
        ),
        outbox = emptyList(), working = false, hasMore = false, requests = emptyList(), notifications = emptyList(),
        notificationsError = null, attachments = emptyList(), provisioning = null, reportEnabled = true, loading = false, sending = false,
        error = null, loadingHistory = false, historyError = null, steeringSupported = null, deliveryIntent = DeliveryIntent.STEER,
        interrupting = false, interruptError = null, deliveries = emptyList())

    private fun author(id: String, name: String, viewer: Boolean = false) = CommentAuthor(id, name, false, viewer)

    @Test fun menuOffersEveryToolNativelyWithoutWebMarkers() {
        val opened = mutableListOf<SessionSheet>()
        compose.setContent {
            MaterialTheme { DropdownMenu(expanded = true, onDismissRequest = {}) { ChatToolsMenuItems(chat, false, onTool = {}, onSheet = { opened += it }, onEnd = {}) } }
        }
        for (title in listOf("Related", "Automation", "Comments", "Share", "Retry", "Fork", "Report")) compose.onNodeWithText(title).performScrollTo().assertExists()
        compose.onAllNodes(hasText("(web)", substring = true)).assertCountEquals(0)
        compose.onNodeWithText("Comments").performScrollTo().performClick()
        compose.onNodeWithText("Fork").performScrollTo().performClick()
        assertEquals(listOf(SessionSheet.Comments, SessionSheet.Derived(DerivedKind.FORK)), opened)
    }

    @Test fun relatedShowsSectionsAndOpensPullRequests() {
        val pr = LinkedPullRequest("https://gh/pr/42", 42u, "Retry token refresh", PullRequestStatus.MERGED, ChecksStatus.PASSED, false)
        val state = LinkedWorkState("p", "s", LinkedWork(
            listOf(LinkedIdea("i", "Silent renewal", "ready", listOf(LinkRelation.WORKS_ON, LinkRelation.EDITED))), LinkedTotal(1u, false, false),
            emptyList(), LinkedTotal(0u, false, false), listOf(pr), LinkedTotal(3u, true, true)), false, null)
        var opened: LinkedPullRequest? = null
        compose.setContent { MaterialTheme { RelatedContent(state, {}, {}, { opened = it }) } }
        compose.onNodeWithText("Working on · Edited").assertIsDisplayed()
        compose.onNodeWithText("Pull requests 3+").assertIsDisplayed()
        compose.onNodeWithText("#42 · Checks passed").assertIsDisplayed()
        compose.onNodeWithText("Merged").assertIsDisplayed()
        compose.onNodeWithText("Files", substring = true).assertDoesNotExist()
        compose.onNodeWithText("Retry token refresh").performClick()
        assertEquals(pr, opened)
    }

    @Test fun relatedExplainsAnEmptyChat() {
        val state = LinkedWorkState("p", "s", LinkedWork(emptyList(), LinkedTotal(0u, false, false), emptyList(), LinkedTotal(0u, false, false), emptyList(), LinkedTotal(0u, false, false)), false, null)
        compose.setContent { MaterialTheme { RelatedContent(state, {}, {}, {}) } }
        compose.onNodeWithText("Nothing related yet").assertIsDisplayed()
    }

    @Test fun automationWordsWaitsAndOffersStopOnlyForStoppableWaits() {
        val ci = ChatWait("ci", WaitEvent.Ci, WaitSubject("pull_request", "42"), "s", WaitOwner.AGENT, null, now - 60_000, null, null, null, true)
        val relay = ChatWait("relay", WaitEvent.Channel(listOf("agent-dm.a")), null, "s", WaitOwner.AGENT, null, now, null, null, null, false)
        val watch = UpcomingAutomation("w", UpcomingKind.WATCH, null, UpcomingStatus.ON, true, null, WaitEvent.Known("issue_comment.created"), null, true, 10u, 10u)
        val state = AutomationState("p", "s", true, true, listOf(ci), listOf(relay), listOf(watch), false, false, false, null, null, null)
        compose.setContent { MaterialTheme { AutomationContent(state, "s", onStop = { _, _ -> }, onRemind = {}) } }
        compose.onNodeWithText("This chat is waiting for CI to finish on PR #42").assertIsDisplayed()
        compose.onNodeWithText("This chat is waiting for a post on #agent-dm.a").assertDoesNotExist()
        compose.onNodeWithText("When someone comments on an issue or PR").assertIsDisplayed()
        compose.onNodeWithText("10 of 10 runs used").assertIsDisplayed()
        compose.onNodeWithText("Check").assertIsDisplayed()
        compose.onNodeWithText("Remind this chat later").assertIsDisplayed()
        compose.onNodeWithText("Show SAM's own message relays (1)").assertIsDisplayed()
        compose.onAllNodes(isToggleable())[0].performClick()
        compose.onNodeWithText("This chat is waiting for a post on #agent-dm.a").assertIsDisplayed()
        // Only the agent's own wait is stoppable; SAM relays never are. (Material dialogs with a
        // text field never idle under Robolectric, so the confirmation itself is not driven here;
        // the cancel request body is asserted in core/tests/session_tools.rs.)
        compose.onAllNodesWithText("Stop waiting").assertCountEquals(1)
    }

    @Test fun commentsOpenOnNeedsYouAndReplySendsToTheAgent() {
        val question = CommentThread("t1", "a1", "token refresh", author("bo", "Bo"), "Cover expired tokens?", CommentStatus.OPEN, CommentBucket.NEEDS_YOU, now, now, emptyList())
        val resolved = CommentThread("t2", "u1", null, author("me", "Me", true), "Looks good", CommentStatus.RESOLVED, CommentBucket.RESOLVED, now - 1, now - 1, emptyList())
        val state = CommentsState("p", "s", true, listOf(question, resolved), CommentCounts(2u, 1u, 0u, 0u, 1u), false, true, true, false, false, null)
        var opened by mutableStateOf<CommentThread?>(null)
        var reply: Pair<String, Boolean>? = null
        compose.setContent {
            MaterialTheme {
                if (opened == null) CommentsContent(state, chat) { opened = it }
                else CommentThreadContent(opened, state, chat, onReply = { body, send, done -> reply = body to send; done() }, onSend = {}, onResolve = {}, onReopen = {})
            }
        }
        compose.onNodeWithText("Cover expired tokens?").assertIsDisplayed()
        compose.onNodeWithText("Looks good").assertDoesNotExist()
        compose.onNodeWithText("Bo commented").assertIsDisplayed()
        compose.onNodeWithText("Cover expired tokens?").performClick()
        compose.onNodeWithText("On the agent's reply").assertIsDisplayed()
        compose.onNodeWithText("I fixed it and opened PR #42.").assertIsDisplayed()
        compose.onNodeWithText("Reply…").performTextInput("Yes, include them.")
        compose.onAllNodesWithText("Send to agent").onLast().performClick()
        compose.onNodeWithText("Reply & send").performClick()
        assertEquals("Yes, include them." to true, reply)
    }

    @Test fun readersCanCommentButNotSendToTheAgent() {
        val state = CommentsState("p", "s", true, emptyList(), CommentCounts(0u, 0u, 0u, 0u, 0u), false, true, false, false, false, null)
        var created: Pair<String, Boolean>? = null
        compose.setContent { MaterialTheme { NewCommentContent("u1", state, chat) { body, send -> created = body to send } } }
        compose.onNodeWithText("Please fix the token refresh.").assertIsDisplayed()
        compose.onNodeWithText("Send to agent").assertDoesNotExist()
        compose.onNodeWithText("Visible to everyone in this project. Doesn't message the agent.").assertIsDisplayed()
        compose.onNodeWithText("Add a comment…").performTextInput("Check mobile")
        compose.onNodeWithText("Comment").performClick()
        assertEquals("Check mobile" to false, created)
    }

    private fun access(canAdd: Boolean = true, none: NoCandidates? = null) = SessionAccessState(
        "p", "s", true, ViewerAccess.OWNER, AccessPerson("me", "Léa", true),
        listOf(AccessGrant("g", AccessPerson("bo", "Bo", false), AccessPerson("me", "Léa", true), now - 60_000, now + 20 * 60_000, 30u)),
        true, canAdd, true, if (none == null) listOf(ShareCandidate("ana", "Ana", "ana@x")) else emptyList(), none, null, 0, null, false, false, null)

    @Test fun shareListsPeopleAndOffersTeammates() {
        var added: String? = null
        var revoked: String? = null
        compose.setContent { MaterialTheme { ShareContent(access(), { added = it.userId }, {}, { revoked = it.grantee.id }) } }
        compose.onNodeWithText("Léa (you)").assertIsDisplayed()
        compose.onNodeWithText("Owner").assertIsDisplayed()
        compose.onNodeWithText("added by you", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Ana").performClick()
        assertEquals("ana", added)
        compose.onNodeWithText("Revoke now").performClick()
        compose.onNodeWithText("Revoke Bo's access now?", substring = true).assertIsDisplayed()
        compose.onAllNodesWithText("Revoke now").onLast().performClick()
        assertEquals("bo", revoked)
    }

    @Test fun shareExplainsWhyNobodyCanBeAdded() {
        compose.setContent { MaterialTheme { ShareContent(access(canAdd = false), {}, {}, {}) } }
        compose.onNodeWithText("This chat has ended, so no one else can be added.").assertIsDisplayed()
    }

    @Test fun shareRequiresADurationAndTheAcknowledgement() {
        var confirmed: UInt? = null
        compose.setContent { MaterialTheme { ShareConfirmContent(access(), "Ana", false, listOf(5u, 10u, 30u, 60u), { now + it.toLong() * 60_000 }) { confirmed = it } } }
        compose.onNodeWithText("Share with Ana?").assertIsDisplayed()
        val share = compose.onNode(hasText("Share") and hasClickAction())
        share.performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText("30 min").performScrollTo().performClick()
        share.assertIsNotEnabled()
        compose.onNodeWithText("Ends at", substring = true).assertExists()
        compose.onNode(isToggleable()).performScrollTo().performClick()
        share.assertIsEnabled().performClick()
        assertEquals(30u, confirmed)
    }

    @Test fun reportListsReferencesOnlyWhenAttached() {
        var sent: Triple<String, String, Boolean>? = null
        val refs = ReportRefs("s", "t", null)
        compose.setContent { MaterialTheme { ReportContent(ReportState(false, null, null), refs, listOf("sessionId", "taskId")) { t, d, a -> sent = Triple(t, d, a) } } }
        compose.onNodeWithText("Submit").assertIsNotEnabled()
        compose.onNodeWithText("Chat session").assertDoesNotExist()
        compose.onNodeWithText("Brief summary of the issue").performTextInput("Menu froze")
        compose.onNodeWithText("What happened? What did you expect?").performTextInput("After a retry")
        compose.onNode(isToggleable()).performClick()
        compose.onNodeWithText("Chat session").assertIsDisplayed()
        compose.onNodeWithText("Submit").performScrollTo().performClick()
        assertEquals(Triple("Menu froze", "After a retry", true), sent)
    }

    @Test fun retryBannerShowsTheParentAndPromptState() {
        val derived = DerivedTask(DerivedKind.RETRY, "s", "Fix login", "t", "sam/fix", "Tests failed", true, null)
        compose.setContent { MaterialTheme { DerivedBanner(DerivedKind.RETRY, derived) } }
        compose.onNodeWithText("Retrying: Fix login").assertIsDisplayed()
        compose.onNodeWithText("Branch: sam/fix").assertIsDisplayed()
        compose.onNodeWithText("Error: Tests failed").assertIsDisplayed()
        compose.onNodeWithText("Loading original prompt…").assertIsDisplayed()
    }
}
