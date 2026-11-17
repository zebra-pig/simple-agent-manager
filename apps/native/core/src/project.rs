//! One project: its chat sessions, newest activity first, and the composer
//! that submits a new task (with attached files, see attachments.rs, and the
//! chosen agent profile, see agent_profiles.rs) to an agent. The profile
//! editor works on this view model too, so the composer's list stays current.

use crate::agent_profiles::{self, AgentList, AgentOption, AgentProfile, PickerState, ProfileDraft, ProfileList};
use crate::api::{ChatSession, SessionPage, SubmitTask, SubmittedTask};
use crate::attachments::{self, Attachment};
use crate::error::{CoreError, Result, UserError};
use crate::session::seg;

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ProjectState {
    pub project_id: String,
    pub sessions: Vec<ChatSession>,
    pub search_query: String,
    pub matching_sessions: Vec<ChatSession>,
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
    /// Accepted submission awaiting the shell's draft-clear/navigation handoff.
    pub submitted_session_id: Option<String>,
    /// A profile is being saved or deleted.
    pub saving_profile: bool,
    /// Why the last profile save or delete failed, shown in the editor.
    pub profile_error: Option<UserError>,
    pub error: Option<UserError>,
}

observable!(ProjectViewModel, ProjectState, ProjectObserver);
observable_attachments!(ProjectViewModel);

const SESSION_PAGE_SIZE: usize = 50;

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
        let (sessions, profiles) = tokio::join!(self.fetch_sessions(&project_id), self.fetch_profiles(&project_id));
        self.update(|s| {
            if s.project_id != project_id {
                return; // another project was opened meanwhile
            }
            s.loading = false;
            s.error = None;
            match sessions {
                Ok(sessions) => {
                    s.sessions = sessions;
                    s.filter_sessions();
                }
                Err(e) => s.error = Some(UserError::from(&e)),
            }
            match profiles {
                Ok(profiles) => s.set_profiles(profiles),
                Err(e) => s.error = s.error.take().or(Some(UserError::from(&e))),
            }
        });
    }

    /// Search titles and session IDs without discarding the complete list.
    pub fn search_sessions(&self, query: String) {
        self.update(|s| {
            s.search_query = query;
            s.filter_sessions();
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
    /// `None` (the reason is in `state.error`). On success, the shell must clear
    /// its draft, open the session, then call `finish_submission`.
    pub async fn submit_task(&self, message: String) -> Option<SubmittedTask> {
        // Validate, snapshot and claim together: no stale draft/attachments can
        // slip between a state read and acquiring the submission lock.
        let mut submission = None;
        self.update(|s| {
            if s.submitting || s.project_id.is_empty() {
                return;
            }
            let files = match attachments::ready(&s.attachments) {
                Ok(files) => files,
                Err(e) => {
                    s.error = Some(e);
                    return;
                }
            };
            let message = attachments::message_text(&message, !files.is_empty());
            if message.is_empty() {
                return;
            }
            s.submitting = true;
            s.error = None;
            submission = Some((s.project_id.clone(), s.attachments.clone(), s.selected_profile_id.clone(), files, message));
        });
        let (project_id, attached, selected_profile_id, files, message) = submission?;
        let body = SubmitTask { message: &message, agent_profile_id: selected_profile_id.as_deref(), attachments: &files };
        let result: Result<SubmittedTask> = self.app.post(&format!("/api/projects/{}/tasks/submit", seg(&project_id)), &body).await;
        let mut current = false;
        self.update(|s| {
            if s.project_id != project_id {
                return;
            }
            current = true;
            match &result {
                // Files added while this was on its way stay for the next task.
                Ok(task) => {
                    let documents = attached.iter().filter_map(crate::documents::from_attachment).collect::<Vec<_>>();
                    if !documents.is_empty() {
                        let started = crate::chat::StartedChat { text: message.clone(), attachments: documents };
                        self.app.remember_started_chat(&task.session_id, started);
                    }
                    s.submitted_session_id = Some(task.session_id.clone());
                    s.attachments.retain(|a| !attached.iter().any(|sent| sent.id == a.id));
                }
                Err(e) => {
                    s.submitting = false;
                    s.error = Some(UserError::from(e));
                }
            }
        });
        let submitted = result.ok()?;
        if !current {
            return None;
        }
        self.load(project_id.clone()).await;
        let state = self.state();
        if state.project_id != project_id || state.submitted_session_id.as_deref() != Some(&submitted.session_id) {
            return None;
        }
        // Returning to the shell is not the end of submission: the draft is still
        // visible until its continuation runs. Only its explicit handoff unlocks.
        Some(submitted)
    }

    /// The shell cleared the draft and opened this accepted session. A stale or
    /// unrelated handoff cannot unlock a different submission.
    pub fn finish_submission(&self, session_id: String) {
        self.update(|s| {
            if s.submitted_session_id.as_deref() == Some(&session_id) {
                s.submitted_session_id = None;
                s.submitting = false;
            }
        });
    }
}

impl ProjectViewModel {
    /// Read every recency page so older chats remain searchable. Commit the
    /// snapshot only after all pages succeed, preserving visible data on error.
    async fn fetch_sessions(&self, project_id: &str) -> Result<Vec<ChatSession>> {
        let mut sessions = Vec::new();
        let mut offset = 0;
        let mut seen = std::collections::HashSet::new();
        loop {
            let path = if offset == 0 {
                format!("/api/projects/{}/sessions?limit={SESSION_PAGE_SIZE}", seg(project_id))
            } else {
                format!("/api/projects/{}/sessions?limit={SESSION_PAGE_SIZE}&offset={offset}", seg(project_id))
            };
            let page: SessionPage = self.app.get(&path).await?;
            // The server may skip malformed rows after applying LIMIT/OFFSET.
            // Advance by the requested window, not the valid row count.
            offset += SESSION_PAGE_SIZE;
            let before = sessions.len();
            sessions.extend(page.sessions.into_iter().filter(|s| seen.insert(s.id.clone())));
            if !page.has_more {
                break;
            }
            if sessions.len() == before {
                return Err(CoreError::Unexpected("session pagination made no progress".into()));
            }
            // Stop work if the model has moved to another project.
            if self.state().project_id != project_id {
                return Ok(Vec::new());
            }
        }
        sessions.sort_by(|a, b| b.last_activity().cmp(&a.last_activity()).then_with(|| a.id.cmp(&b.id)));
        Ok(sessions)
    }

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
    fn filter_sessions(&mut self) {
        let query = self.search_query.trim().to_lowercase();
        self.matching_sessions = self
            .sessions
            .iter()
            .filter(|session| {
                query.is_empty()
                    || session.topic.as_deref().unwrap_or("").to_lowercase().contains(&query)
                    || session.id.to_lowercase().contains(&query)
            })
            .cloned()
            .collect();
    }

    fn set_profiles(&mut self, profiles: Vec<AgentProfile>) {
        self.selected_profile_id = agent_profiles::preselect(self.selected_profile_id.as_deref(), &profiles);
        self.profiles = profiles;
    }
}
