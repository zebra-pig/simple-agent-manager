//! One chat session: the conversation with the agent, the task it runs, and
//! follow-up prompts (with attached files, see attachments.rs). The shell calls `refresh` every few seconds while the
//! screen is visible; there is no push channel yet.

use crate::api::{merge_messages, ChatMessage, ChatSession, Prompt, SessionDetail};
use crate::attachments::{self, Attachment};
use crate::error::UserError;
use crate::provisioning::{ProvisioningState, ProvisioningTask};
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
    /// Visible only during first-boot VM/container setup.
    pub provisioning: Option<ProvisioningState>,
    pub report_enabled: bool,
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
            match result {
                Ok(detail) => {
                    if let Some(provisioning) = provisioning {
                        s.provisioning = provisioning;
                    }
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
