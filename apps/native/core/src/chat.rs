//! One chat session: the conversation with the agent (built from the stored
//! rows, see timeline.rs), the task it runs, and follow-up prompts (with
//! attached files, see attachments.rs). The shell calls `refresh` every few
//! seconds while the screen is visible; there is no push channel yet.

use std::sync::atomic::{AtomicU64, Ordering};

use crate::api::{ChatSession, Prompt, SessionDetail};
use crate::attachments::{self, Attachment};
use crate::error::UserError;
use crate::provisioning::{ProvisioningState, ProvisioningTask};
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
    pub requests: Vec<crate::notifications::RequestRef>,
    pub notifications: Vec<crate::Notification>,
    pub notifications_error: Option<UserError>,
    /// Files for the next follow-up.
    pub attachments: Vec<Attachment>,
    /// Visible only during first-boot VM/container setup.
    pub provisioning: Option<ProvisioningState>,
    pub report_enabled: bool,
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
    pub attachments: Vec<crate::ChatDocument>,
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
        let current = self.state();
        let config: crate::error::Result<serde_json::Value> = self.app.get("/api/report-issue/config").await;
        if let Ok(config) = config {
            self.update(|s| {
                if s.project_id == current.project_id && s.session_id == current.session_id {
                    s.report_enabled = config["enabled"].as_bool().unwrap_or(false);
                }
            });
        }
    }

    /// Intent: pull the latest messages and task status.
    pub async fn refresh(&self) {
        let ChatState { project_id, session_id, .. } = self.state();
        if session_id.is_empty() {
            return;
        }
        let result: crate::error::Result<SessionDetail> =
            self.app.get(&format!("/api/projects/{}/sessions/{}", seg(&project_id), seg(&session_id))).await;
        let notifications = crate::notifications::fetch_notifications(&self.app, &project_id, &session_id).await;
        // The session embed lacks startedAt/admissionState. Read the full task
        // only during setup so wake-ups and provider holds use the same gates as web.
        let provisioning = if let Ok(detail) = &result {
            if let Some(task) = detail.session.task.as_ref().filter(|t| {
                detail.session.status == crate::api::SessionStatus::Active && matches!(t.status.as_str(), "queued" | "delegated")
            }) {
                let task: crate::error::Result<ProvisioningTask> =
                    self.app.get(&format!("/api/projects/{}/tasks/{}", seg(&project_id), seg(&task.id))).await;
                // Keep the last snapshot during a transient task-fetch failure.
                task.map(|t| t.state(&detail.session)).ok()
            } else {
                Some(None)
            }
        } else {
            None
        };
        self.update(|s| {
            if s.project_id != project_id || s.session_id != session_id {
                return;
            }
            s.loading = false;
            match notifications {
                Ok(items) => {
                    s.notifications = items;
                    s.notifications_error = None;
                }
                Err(e) => s.notifications_error = Some(UserError::from(&e)),
            }
            match result {
                Ok(detail) => {
                    s.working = detail.working();
                    s.has_more = detail.has_more;
                    s.requests.clear();
                    for row in &detail.messages {
                        if let Some(meta) = &row.tool_metadata {
                            crate::notifications::collect_refs(meta, &mut s.requests, 0);
                        }
                        if row.role == "tool" {
                            crate::notifications::collect_refs(&serde_json::Value::String(row.content.clone()), &mut s.requests, 0);
                        }
                    }
                    s.items = timeline::build(detail.messages, s.working);
                    if let Some(provisioning) = provisioning {
                        s.provisioning = provisioning;
                    }
                    s.session = Some(detail.session);
                    let items = &s.items;
                    // Accepted messages leave the outbox once the chat has them.
                    s.outbox.retain(|m| !m.accepted || user_count(items, &m.text, &m.attachments) <= m.baseline);
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
            let attachments = attached.iter().filter_map(crate::documents::from_attachment).collect::<Vec<_>>();
            let display_content = if !attachments.is_empty() && content == attachments::DEFAULT_ATTACHMENT_MESSAGE { String::new() } else { content.clone() };
            let baseline = user_count(&s.items, &display_content, &attachments);
            s.outbox.push(OutgoingMessage { id: local_id.clone(), text: display_content, accepted: false, baseline, attachments });
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

fn user_count(items: &[ChatItem], text: &str, attachments: &[crate::ChatDocument]) -> u32 {
    let text = text.trim();
    items.iter().filter(|i| matches!(&i.content, ChatContent::User { text: t, attachments: a } if t.trim() == text && a.iter().map(|d| &d.file_id).eq(attachments.iter().map(|d| &d.file_id)))).count() as u32
}

#[uniffi::export(async_runtime = "tokio")]
impl ChatViewModel {
    /// Fetch only a file referenced in the currently displayed project transcript.
    /// The shell owns its temporary preview and the OS file viewer.
    pub async fn document_bytes(&self, file_id: String) -> Option<Vec<u8>> {
        let state = self.state();
        let allowed = state.items.iter().any(|m| match &m.content {
            ChatContent::Document { document } => document.file_id == file_id && !document.unavailable,
            ChatContent::User { attachments, .. } => attachments.iter().any(|d| d.file_id == file_id && !d.unavailable),
            _ => false,
        }) || state.outbox.iter().any(|m| m.attachments.iter().any(|d| d.file_id == file_id));
        if !allowed || file_id.is_empty() { return None }
        if let Some((upload, filename)) = file_id.strip_prefix("attachment:").and_then(|s| s.split_once('/')) {
            return self.app.attachment_bytes(&state.project_id, upload, filename).await.ok();
        }
        self.app.library_bytes(&state.project_id, &file_id).await.ok()
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl ChatViewModel {
    /// Web's Complete/Cancel gate is evaluated again at confirmation time.
    pub async fn end_task(&self) {
        let state = self.state();
        let Some(session) = state.session.filter(|s| s.can_drive()) else { return };
        let Some(task) = session.task else { return };
        let status = match task.status.as_str() {
            "in_progress" | "sleeping" => "completed",
            "draft" | "ready" | "queued" | "delegated" => "cancelled",
            _ => return,
        };
        let result: crate::error::Result<serde_json::Value> = self
            .app
            .post(
                &format!("/api/projects/{}/tasks/{}/status", seg(&state.project_id), seg(&task.id)),
                &serde_json::json!({"status": status}),
            )
            .await;
        if let Err(e) = result {
            self.update(|s| s.error = Some(UserError::from(&e)));
        } else {
            self.refresh().await;
        }
    }
    pub fn web_url(&self) -> String {
        let s = self.state();
        let base = self.app.state().server_url.replacen("://api.", "://app.", 1);
        format!("{base}/projects/{}/chat/{}", seg(&s.project_id), seg(&s.session_id))
    }
}

/// Tools handed to web open a panel or a prefilled composer; never execute an action.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WebChatTool {
    Related,
    Automation,
    Comments,
    Share,
    Retry,
    Fork,
    Report,
}
#[uniffi::export]
impl ChatViewModel {
    pub fn web_tool_url(&self, tool: WebChatTool) -> String {
        let name = match tool {
            WebChatTool::Related => "related",
            WebChatTool::Automation => "automation",
            WebChatTool::Comments => "comments",
            WebChatTool::Share => "share",
            WebChatTool::Retry => "retry",
            WebChatTool::Fork => "fork",
            WebChatTool::Report => "report",
        };
        format!("{}?tool={name}", self.web_url())
    }
}
