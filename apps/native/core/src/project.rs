//! One project: its chat sessions, newest activity first, and the composer
//! that submits a new task (with attached files, see attachments.rs) to an agent.

use crate::api::{ChatSession, SessionPage, SubmitTask, SubmittedTask};
use crate::attachments::{self, Attachment};
use crate::error::UserError;
use crate::session::seg;

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ProjectState {
    pub project_id: String,
    pub sessions: Vec<ChatSession>,
    /// Files for the next task.
    pub attachments: Vec<Attachment>,
    pub loading: bool,
    pub submitting: bool,
    pub error: Option<UserError>,
}

observable!(ProjectViewModel, ProjectState, ProjectObserver);
observable_attachments!(ProjectViewModel);

#[uniffi::export(async_runtime = "tokio")]
impl ProjectViewModel {
    /// Intent: show `project_id` and (re)load its sessions.
    pub async fn load(&self, project_id: String) {
        self.update(|s| {
            if s.project_id != project_id {
                *s = ProjectState { project_id: project_id.clone(), ..Default::default() };
            }
            s.loading = true;
        });
        let result: crate::error::Result<SessionPage> =
            self.app.get(&format!("/api/projects/{}/sessions?limit=50", seg(&project_id))).await;
        self.update(|s| {
            if s.project_id != project_id {
                return; // another project was opened meanwhile
            }
            s.loading = false;
            match result {
                Ok(mut page) => {
                    page.sessions.sort_by_key(|x| std::cmp::Reverse(x.last_activity()));
                    s.sessions = page.sessions;
                    s.error = None;
                }
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
    }

    /// Intent: hand `message` and the attached files to an agent as a new
    /// task. Returns the new session to open, or `None` (the reason is in
    /// `state.error`).
    pub async fn submit_task(&self, message: String) -> Option<SubmittedTask> {
        let ProjectState { project_id, attachments: attached, .. } = self.state();
        let files = match attachments::ready(&attached) {
            Ok(files) => files,
            Err(e) => {
                self.update(|s| s.error = Some(e));
                return None;
            }
        };
        let message = attachments::message_text(&message, !files.is_empty());
        if message.is_empty() || project_id.is_empty() {
            return None;
        }
        self.update(|s| s.submitting = true);
        let result: crate::error::Result<SubmittedTask> = self
            .app
            .post(&format!("/api/projects/{}/tasks/submit", seg(&project_id)), &SubmitTask { message: &message, attachments: &files })
            .await;
        self.update(|s| {
            s.submitting = false;
            match &result {
                // Files added while this was on its way stay for the next task.
                Ok(_) => s.attachments.retain(|a| !attached.iter().any(|sent| sent.id == a.id)),
                Err(e) => s.error = Some(UserError::from(e)),
            }
        });
        let submitted = result.ok()?;
        self.load(project_id).await;
        Some(submitted)
    }
}
