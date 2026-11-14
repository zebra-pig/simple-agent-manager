//! One chat session: the conversation with the agent, the task it runs, and
//! follow-up prompts (with attached files, see attachments.rs). The shell calls `refresh` every few seconds while the
//! screen is visible; there is no push channel yet.

use crate::api::{merge_messages, ChatMessage, ChatSession, Prompt, SessionDetail};
use crate::attachments::{self, Attachment};
use crate::error::UserError;
use crate::session::seg;

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ChatState {
    pub project_id: String,
    pub session_id: String,
    pub session: Option<ChatSession>,
    /// Oldest first, streamed chunks merged into whole messages.
    pub messages: Vec<ChatMessage>,
    /// Files for the next follow-up.
    pub attachments: Vec<Attachment>,
    pub loading: bool,
    pub sending: bool,
    pub error: Option<UserError>,
}

observable!(ChatViewModel, ChatState, ChatObserver);
observable_attachments!(ChatViewModel);

#[uniffi::export(async_runtime = "tokio")]
impl ChatViewModel {
    /// Intent: show this session (first load or a switch).
    pub async fn load(&self, project_id: String, session_id: String) {
        self.update(|s| {
            if s.project_id != project_id || s.session_id != session_id {
                *s = ChatState { project_id, session_id, ..Default::default() };
            }
            s.loading = true;
        });
        self.refresh().await;
    }

    /// Intent: pull the latest messages and task status.
    pub async fn refresh(&self) {
        let ChatState { project_id, session_id, .. } = self.state();
        if session_id.is_empty() {
            return;
        }
        let result: crate::error::Result<SessionDetail> =
            self.app.get(&format!("/api/projects/{}/sessions/{}", seg(&project_id), seg(&session_id))).await;
        self.update(|s| {
            if s.session_id != session_id {
                return;
            }
            s.loading = false;
            match result {
                Ok(detail) => {
                    s.session = Some(detail.session);
                    s.messages = merge_messages(detail.messages);
                    s.error = None;
                }
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
    }

    /// Intent: send a follow-up to the agent, with the attached files. `true`
    /// when it was accepted, so the shell can clear the composer.
    pub async fn send(&self, content: String) -> bool {
        let ChatState { project_id, session_id, attachments: attached, .. } = self.state();
        let files = match attachments::ready(&attached) {
            Ok(files) => files,
            Err(e) => {
                self.update(|s| s.error = Some(e));
                return false;
            }
        };
        let content = attachments::message_text(&content, !files.is_empty());
        if content.is_empty() || session_id.is_empty() {
            return false;
        }
        self.update(|s| s.sending = true);
        let result: crate::error::Result<serde_json::Value> = self
            .app
            .post(
                &format!("/api/projects/{}/sessions/{}/prompt", seg(&project_id), seg(&session_id)),
                &Prompt { content: &content, attachments: &files },
            )
            .await;
        let ok = result.is_ok();
        self.update(|s| {
            s.sending = false;
            match result {
                // Files added while this was on its way stay for the next one.
                Ok(_) => s.attachments.retain(|a| !attached.iter().any(|sent| sent.id == a.id)),
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
        if ok {
            self.refresh().await;
        }
        ok
    }
}
