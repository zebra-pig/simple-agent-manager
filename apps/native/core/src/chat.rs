//! One chat session: the conversation with the agent (built from the stored
//! rows, see timeline.rs), the task it runs, and follow-up prompts (with
//! attached files, see attachments.rs). The shell calls `refresh` every few
//! seconds while the screen is visible; there is no push channel yet.

use std::sync::atomic::{AtomicU64, Ordering};

use crate::api::{ChatSession, Prompt, SessionDetail};
use crate::attachments::{self, Attachment};
use crate::error::UserError;
use crate::session::seg;
use crate::timeline::{self, ChatContent, ChatItem};

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ChatState {
    pub project_id: String,
    pub session_id: String,
    pub session: Option<ChatSession>,
    /// The conversation, oldest first.
    pub items: Vec<ChatItem>,
    /// Follow-ups sent from here that aren't in `items` yet, oldest first.
    /// Shown after `items`, marked as on their way.
    pub outbox: Vec<OutgoingMessage>,
    /// The agent is mid-turn.
    pub working: bool,
    /// The server has older messages than the ones in `items`.
    pub has_more: bool,
    /// Files for the next follow-up.
    pub attachments: Vec<Attachment>,
    pub loading: bool,
    pub sending: bool,
    pub error: Option<UserError>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct OutgoingMessage {
    /// Local; not a server id.
    pub id: String,
    pub text: String,
    /// The server accepted it; it shows up in `items` on a later refresh.
    pub accepted: bool,
    /// How many user messages with this text the chat had when it was sent:
    /// one more means it arrived.
    pub baseline: u32,
}

static NEXT_LOCAL_ID: AtomicU64 = AtomicU64::new(1);

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
            if s.project_id != project_id || s.session_id != session_id {
                return;
            }
            s.loading = false;
            match result {
                Ok(detail) => {
                    s.working = detail.working();
                    s.has_more = detail.has_more;
                    s.items = timeline::build(detail.messages, s.working);
                    s.session = Some(detail.session);
                    let items = &s.items;
                    // Accepted messages leave the outbox once the chat has them.
                    s.outbox.retain(|m| !m.accepted || user_count(items, &m.text) <= m.baseline);
                    s.error = None;
                }
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
    }

    /// Intent: send a follow-up to the agent, with the attached files. It shows
    /// in `outbox` right away. `true` when the server accepted it; on `false`
    /// it is gone from the outbox again (the reason is in `state.error`), so
    /// the shell can put the text back in the composer.
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
        let local_id = format!("local-{}", NEXT_LOCAL_ID.fetch_add(1, Ordering::Relaxed));
        let mut started = false;
        self.update(|s| {
            if s.sending || s.project_id != project_id || s.session_id != session_id {
                return;
            }
            started = true;
            s.sending = true;
            s.error = None;
            let baseline = user_count(&s.items, &content);
            s.outbox.push(OutgoingMessage { id: local_id.clone(), text: content.clone(), accepted: false, baseline });
        });
        if !started {
            return false;
        }
        let result: crate::error::Result<serde_json::Value> = self
            .app
            .post(
                &format!("/api/projects/{}/sessions/{}/prompt", seg(&project_id), seg(&session_id)),
                &Prompt { content: &content, attachments: &files },
            )
            .await;
        let ok = result.is_ok();
        self.update(|s| {
            if s.project_id != project_id || s.session_id != session_id {
                return;
            }
            s.sending = false;
            match result {
                Ok(_) => {
                    // Files added while this was on its way stay for the next one.
                    s.attachments.retain(|a| !attached.iter().any(|sent| sent.id == a.id));
                    if let Some(m) = s.outbox.iter_mut().find(|m| m.id == local_id) {
                        m.accepted = true;
                    }
                }
                Err(e) => {
                    s.outbox.retain(|m| m.id != local_id);
                    s.error = Some(UserError::from(&e));
                }
            }
        });
        if ok {
            self.refresh().await;
        }
        ok
    }
}

fn user_count(items: &[ChatItem], text: &str) -> u32 {
    let text = text.trim();
    items.iter().filter(|i| matches!(&i.content, ChatContent::User { text: t } if t.trim() == text)).count() as u32
}
