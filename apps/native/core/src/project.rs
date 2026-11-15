//! One project: its chat sessions, newest activity first, and the composer
//! that submits a new task (with attached files, see attachments.rs, and the
//! chosen agent profile, see agent_profiles.rs) to an agent. The profile
//! editor works on this view model too, so the composer's list stays current.

use crate::agent_profiles::{self, AgentList, AgentOption, AgentProfile, PickerState, ProfileDraft, ProfileList};
use crate::api::{ChatSession, SessionPage, SubmitTask, SubmittedTask};
use crate::attachments::{self, Attachment};
use crate::error::{Result, UserError};
use crate::session::seg;

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ProjectState {
    pub project_id: String,
    pub sessions: Vec<ChatSession>,
    /// Files for the next task.
    pub attachments: Vec<Attachment>,
    /// The profiles a new chat can start with: the user's recent ones first,
    /// hidden ones left out.
    pub profiles: Vec<AgentProfile>,
    /// The profile the next task runs with. `None` when the project has none:
    /// the server then uses the project's defaults.
    pub selected_profile_id: Option<String>,
    /// The agents a profile can run, for the editor (`load_agents`).
    pub agents: Vec<AgentOption>,
    pub loading: bool,
    pub submitting: bool,
    /// A profile is being saved or deleted.
    pub saving_profile: bool,
    /// Why the last profile save or delete failed, shown in the editor.
    pub profile_error: Option<UserError>,
    pub error: Option<UserError>,
}

observable!(ProjectViewModel, ProjectState, ProjectObserver);
observable_attachments!(ProjectViewModel);

#[uniffi::export(async_runtime = "tokio")]
impl ProjectViewModel {
    /// Intent: show `project_id` and (re)load its sessions and profiles.
    pub async fn load(&self, project_id: String) {
        self.update(|s| {
            if s.project_id != project_id {
                *s = ProjectState { project_id: project_id.clone(), ..Default::default() };
            }
            s.loading = true;
        });
        let sessions_path = format!("/api/projects/{}/sessions?limit=50", seg(&project_id));
        let (sessions, profiles) = tokio::join!(self.app.get::<SessionPage>(&sessions_path), self.fetch_profiles(&project_id));
        self.update(|s| {
            if s.project_id != project_id {
                return; // another project was opened meanwhile
            }
            s.loading = false;
            s.error = None;
            match sessions {
                Ok(mut page) => {
                    page.sessions.sort_by_key(|x| std::cmp::Reverse(x.last_activity()));
                    s.sessions = page.sessions;
                }
                Err(e) => s.error = Some(UserError::from(&e)),
            }
            match profiles {
                Ok(profiles) => s.set_profiles(profiles),
                Err(e) => s.error = s.error.take().or(Some(UserError::from(&e))),
            }
        });
    }

    /// Intent: run the next task with this profile.
    pub fn select_profile(&self, profile_id: String) {
        self.update(|s| {
            if s.profiles.iter().any(|p| p.id == profile_id) {
                s.selected_profile_id = Some(profile_id);
            }
        });
    }

    /// Intent: the editor opens; loads the agents to choose from (once) and
    /// clears the last editor error.
    pub async fn load_agents(&self) {
        let mut need = false;
        self.update(|s| {
            s.profile_error = None;
            need = s.agents.is_empty();
        });
        if !need {
            return;
        }
        match self.app.get::<AgentList>("/api/agents").await {
            Ok(list) => self.update(|s| s.agents = list.agents),
            // The editor still works with the agent the profile has.
            Err(e) => self.update(|s| s.profile_error = Some(UserError::from(&e))),
        }
    }

    /// Intent: save the editor's `draft`, as a new profile (`profile_id` `None`)
    /// or over an existing one. On success the list reloads, the saved profile
    /// is selected, and it returns `true` so the shell closes the editor;
    /// otherwise the reason is in `state.profile_error`.
    pub async fn save_profile(&self, profile_id: Option<String>, draft: ProfileDraft) -> bool {
        let body = match draft.body() {
            Ok(body) => body,
            Err(e) => {
                self.update(|s| s.profile_error = Some(e));
                return false;
            }
        };
        let Some(project_id) = self.begin_profile_change() else { return false };
        let base = format!("/api/projects/{}/agent-profiles", seg(&project_id));
        let result: Result<AgentProfile> = match &profile_id {
            Some(id) => self.app.put(&format!("{base}/{}", seg(id)), &body).await,
            None => self.app.post(&base, &body).await,
        };
        self.finish_profile_change(&project_id, result.map(|p| Some(p.id))).await
    }

    /// Intent: delete a profile of this project. `true` when it is gone.
    pub async fn delete_profile(&self, profile_id: String) -> bool {
        let Some(project_id) = self.begin_profile_change() else { return false };
        let result: Result<serde_json::Value> =
            self.app.delete(&format!("/api/projects/{}/agent-profiles/{}", seg(&project_id), seg(&profile_id))).await;
        self.finish_profile_change(&project_id, result.map(|_| None)).await
    }

    /// Intent: hand `message` and the attached files to an agent as a new
    /// task, with the selected profile. Returns the new session to open, or
    /// `None` (the reason is in `state.error`).
    pub async fn submit_task(&self, message: String) -> Option<SubmittedTask> {
        let ProjectState { project_id, attachments: attached, selected_profile_id, .. } = self.state();
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
        // Claim the submission atomically: shell observers can lag behind taps.
        let mut started = false;
        self.update(|s| {
            if !s.submitting && s.project_id == project_id {
                s.submitting = true;
                s.error = None;
                started = true;
            }
        });
        if !started {
            return None;
        }
        let body = SubmitTask { message: &message, agent_profile_id: selected_profile_id.as_deref(), attachments: &files };
        let result: Result<SubmittedTask> = self.app.post(&format!("/api/projects/{}/tasks/submit", seg(&project_id)), &body).await;
        self.update(|s| {
            if s.project_id != project_id {
                return;
            }
            match &result {
                // Files added while this was on its way stay for the next task.
                Ok(_) => s.attachments.retain(|a| !attached.iter().any(|sent| sent.id == a.id)),
                Err(e) => {
                    s.submitting = false;
                    s.error = Some(UserError::from(e));
                }
            }
        });
        let submitted = result.ok()?;
        // Keep the composer busy while refreshing, until the shell can open the chat.
        self.load(project_id.clone()).await;
        self.update(|s| {
            if s.project_id == project_id {
                s.submitting = false;
            }
        });
        Some(submitted)
    }
}

impl ProjectViewModel {
    /// The project's profiles in picker order. The picker state (recent,
    /// hidden) is a nicety: without it the server's order stands.
    async fn fetch_profiles(&self, project_id: &str) -> Result<Vec<AgentProfile>> {
        let base = format!("/api/projects/{}/agent-profiles", seg(project_id));
        let picker_path = format!("{base}/picker");
        let (list, picker) = tokio::join!(self.app.get::<ProfileList>(&base), self.app.get::<PickerState>(&picker_path));
        Ok(agent_profiles::picker_order(project_id, list?.items, &picker.unwrap_or_default()))
    }

    /// Marks a save or delete as running; `None` (and nothing changes) while
    /// another one is, or before a project is loaded.
    fn begin_profile_change(&self) -> Option<String> {
        let mut project_id = None;
        self.update(|s| {
            if !s.saving_profile && !s.project_id.is_empty() {
                s.saving_profile = true;
                s.profile_error = None;
                project_id = Some(s.project_id.clone());
            }
        });
        project_id
    }

    /// Reloads the profiles after a change; `saved` is the profile to select.
    async fn finish_profile_change(&self, project_id: &str, result: Result<Option<String>>) -> bool {
        let saved = match result {
            Ok(saved) => saved,
            Err(e) => {
                self.update(|s| {
                    s.saving_profile = false;
                    s.profile_error = Some(UserError::from(&e));
                });
                return false;
            }
        };
        let profiles = self.fetch_profiles(project_id).await;
        self.update(|s| {
            s.saving_profile = false;
            if s.project_id != project_id {
                return;
            }
            if let Some(id) = saved {
                s.selected_profile_id = Some(id);
            }
            match profiles {
                Ok(profiles) => s.set_profiles(profiles),
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
        true
    }
}

impl ProjectState {
    fn set_profiles(&mut self, profiles: Vec<AgentProfile>) {
        self.selected_profile_id = agent_profiles::preselect(self.selected_profile_id.as_deref(), &profiles);
        self.profiles = profiles;
    }
}
