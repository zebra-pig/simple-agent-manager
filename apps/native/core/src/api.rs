//! The slice of the SAM REST API the app reads, as UniFFI records. Field names
//! follow the API's camelCase JSON (packages/shared/src/types/session.ts, the
//! routes under apps/api/src/routes); anything the app doesn't show is ignored.

use serde::{Deserialize, Serialize};

use crate::attachments::TaskAttachment;

/// `GET /api/auth/get-session` -> `user`.
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
pub struct Viewer {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub email: String,
    #[serde(default)]
    pub image: Option<String>,
}

#[derive(Deserialize)]
pub(crate) struct GetSessionResponse {
    pub user: Viewer,
}

/// `GET /api/projects` -> `projects[]`.
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub repository: Option<String>,
    #[serde(default)]
    pub active_session_count: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectPage {
    pub projects: Vec<Project>,
    #[serde(default)]
    pub next_cursor: Option<String>,
}

/// `chat_sessions.status` (`ChatSessionStatus`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum SessionStatus {
    Active,
    Sleeping,
    Stopped,
    Failed,
    /// A status this build doesn't know yet.
    #[default]
    #[serde(other)]
    Unknown,
}

/// The task a session runs, embedded in the session detail (`ChatSessionTaskEmbed`).
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct TaskSummary {
    pub id: String,
    /// `TaskStatus`: draft, queued, in_progress, completed, failed, cancelled...
    pub status: String,
    #[serde(default)]
    pub execution_step: Option<String>,
    #[serde(default)]
    pub terminal_reason: Option<String>,
    #[serde(default)]
    pub error_message: Option<String>,
    #[serde(default)]
    pub output_branch: Option<String>,
    #[serde(default)]
    pub output_pr_url: Option<String>,
    #[serde(default)]
    pub output_summary: Option<String>,
}

/// `GET /api/projects/:id/sessions` -> `sessions[]`, and the detail's `session`.
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ChatSession {
    #[serde(default)]
    pub workspace_id: Option<String>,
    #[serde(default)]
    pub agent_session_id: Option<String>,
    #[serde(default)]
    pub viewer_access: Option<String>,
    #[serde(default)]
    pub is_mine: bool,
    pub id: String,
    #[serde(default)]
    pub topic: Option<String>,
    #[serde(default)]
    pub status: SessionStatus,
    #[serde(default)]
    pub message_count: u32,
    /// Unix milliseconds.
    #[serde(default)]
    pub started_at: i64,
    /// Unix milliseconds.
    #[serde(default)]
    pub last_message_at: Option<i64>,
    #[serde(default)]
    pub task_id: Option<String>,
    /// Active, and the agent finished its turn: waiting for the user.
    #[serde(default)]
    pub is_idle: bool,
    /// Only in the session detail.
    #[serde(default)]
    pub task: Option<TaskSummary>,
}

impl ChatSession {
    pub fn can_drive(&self) -> bool {
        matches!(self.viewer_access.as_deref(), Some("owner" | "grantee")) || (self.viewer_access.is_none() && self.is_mine)
    }
    /// The latest activity, for sorting and "5 min ago".
    pub fn last_activity(&self) -> i64 {
        self.last_message_at.unwrap_or(self.started_at)
    }
}

#[derive(Deserialize)]
pub(crate) struct SessionPage {
    pub sessions: Vec<ChatSession>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum MessageRole {
    User,
    Assistant,
    System,
    Tool,
    Thinking,
    Plan,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ChatMessage {
    pub id: String,
    pub role: MessageRole,
    #[serde(default)]
    pub content: String,
    /// Unix milliseconds.
    #[serde(default)]
    pub created_at: i64,
}

/// `GET /api/projects/:id/sessions/:sessionId`.
#[derive(Deserialize)]
pub(crate) struct SessionDetail {
    pub session: ChatSession,
    #[serde(default)]
    pub messages: Vec<ChatMessage>,
}

/// `POST /api/projects/:id/tasks/submit`.
#[derive(Serialize)]
pub(crate) struct SubmitTask<'a> {
    pub message: &'a str,
    #[serde(rename = "agentProfileId", skip_serializing_if = "Option::is_none")]
    pub agent_profile_id: Option<&'a str>,
    #[serde(skip_serializing_if = "<[_]>::is_empty")]
    pub attachments: &'a [TaskAttachment],
}

#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct SubmittedTask {
    pub task_id: String,
    pub session_id: String,
}

/// `POST /api/projects/:id/sessions/:sessionId/prompt`.
#[derive(Serialize)]
pub(crate) struct Prompt<'a> {
    pub content: &'a str,
    #[serde(skip_serializing_if = "<[_]>::is_empty")]
    pub attachments: &'a [TaskAttachment],
}

/// The agent stores a reply (and a thought) as one row per streamed chunk; the
/// chat shows consecutive rows of those roles as one message, as the web app
/// does (`MERGED_MESSAGE_ROLES` in packages/shared/src/chat-message-merge.ts).
pub(crate) fn merge_messages(mut rows: Vec<ChatMessage>) -> Vec<ChatMessage> {
    rows.sort_by_key(|m| m.created_at); // stable: equal timestamps keep server order
    let mut out: Vec<ChatMessage> = Vec::with_capacity(rows.len());
    for row in rows {
        let merges = matches!(row.role, MessageRole::Assistant | MessageRole::Thinking);
        match out.last_mut() {
            Some(last) if merges && last.role == row.role => last.content.push_str(&row.content),
            _ => out.push(row),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_session_detail() {
        let json = r#"{
            "session": {
                "id": "s1", "workspaceId": null, "taskId": "t1", "topic": null,
                "status": "active", "messageCount": 3, "startedAt": 1700000000000,
                "endedAt": null, "createdAt": 1700000000000, "agentCompletedAt": null,
                "lastMessageAt": 1700000005000, "isIdle": false, "isTerminated": false,
                "workspaceUrl": null,
                "task": {"id": "t1", "status": "in_progress", "executionStep": "running",
                         "errorMessage": null, "outputBranch": null, "outputPrUrl": null,
                         "outputSummary": null, "finalizedAt": null}
            },
            "messages": [
                {"id": "m2", "sessionId": "s1", "role": "assistant", "content": "Hel", "toolMetadata": null, "createdAt": 2},
                {"id": "m1", "sessionId": "s1", "role": "user", "content": "Hi", "toolMetadata": null, "createdAt": 1},
                {"id": "m3", "sessionId": "s1", "role": "assistant", "content": "lo", "toolMetadata": null, "createdAt": 3},
                {"id": "m4", "sessionId": "s1", "role": "tool", "content": "ls", "toolMetadata": {}, "createdAt": 4},
                {"id": "m5", "sessionId": "s1", "role": "something-new", "content": "?", "createdAt": 5}
            ],
            "hasMore": false
        }"#;
        let detail: SessionDetail = serde_json::from_str(json).unwrap();
        assert_eq!(detail.session.status, SessionStatus::Active);
        assert_eq!(detail.session.task.as_ref().unwrap().status, "in_progress");
        assert_eq!(detail.session.last_activity(), 1700000005000);

        let merged = merge_messages(detail.messages);
        let summary: Vec<_> = merged.iter().map(|m| (m.id.as_str(), m.role, m.content.as_str())).collect();
        assert_eq!(
            summary,
            vec![
                ("m1", MessageRole::User, "Hi"),
                ("m2", MessageRole::Assistant, "Hello"),
                ("m4", MessageRole::Tool, "ls"),
                ("m5", MessageRole::Unknown, "?"),
            ]
        );
    }

    #[test]
    fn parses_project_page_and_unknown_status() {
        let page: ProjectPage = serde_json::from_str(
            r#"{"projects": [{"id": "p1", "name": "SAM", "repository": "o/r", "lastActivityAt": "2026-11-14T00:00:00Z"}], "nextCursor": null}"#,
        )
        .unwrap();
        assert_eq!(page.projects[0].active_session_count, 0);
        assert!(page.next_cursor.is_none());

        let s: ChatSession = serde_json::from_str(r#"{"id": "s", "status": "hibernating", "startedAt": 5}"#).unwrap();
        assert_eq!(s.status, SessionStatus::Unknown);
        assert_eq!(s.last_activity(), 5);
    }
}
