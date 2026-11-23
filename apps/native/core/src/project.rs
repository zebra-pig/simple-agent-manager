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
    /// The next task retries or forks an earlier chat (web's derived session).
    pub derived: Option<DerivedTask>,
    pub error: Option<UserError>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DerivedKind {
    Retry,
    Fork,
}

/// The chat a new task starts from. Its task becomes the new task's parent.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DerivedTask {
    pub kind: DerivedKind,
    pub parent_session_id: String,
    /// The parent chat's title without Markdown, else "Chat 1a2b3c4d".
    pub parent_label: String,
    pub parent_task_id: String,
    pub parent_branch: Option<String>,
    /// Retry: why the parent failed.
    pub error_message: Option<String>,
    /// Retry: the original prompt is still being read; sending waits for it.
    pub prompt_loading: bool,
    /// Retry: the original prompt could not be read; the user types it.
    pub prompt_error: Option<UserError>,
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
    /// its draft, open the session, then call `finish_submission`. Refresh the
    /// list separately after that handoff; reads must not delay an accepted task.
    pub async fn submit_task(&self, message: String) -> Option<SubmittedTask> {
        // Validate, snapshot and claim together: no stale draft/attachments can
        // slip between a state read and acquiring the submission lock.
        let mut submission = None;
        self.update(|s| {
            if s.submitting || s.project_id.is_empty() || s.derived.as_ref().is_some_and(|d| d.prompt_loading) {
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
            let parent = s.derived.as_ref().map(|d| d.parent_task_id.clone());
            submission = Some((s.project_id.clone(), s.attachments.clone(), s.selected_profile_id.clone(), files, message, parent));
        });
        let (project_id, attached, selected_profile_id, files, message, parent) = submission?;
        let body = SubmitTask {
            message: &message,
            agent_profile_id: selected_profile_id.as_deref(),
            attachments: &files,
            parent_task_id: parent.as_deref(),
        };
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
                    s.derived = None;
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
        // Returning to the shell is not the end of submission: the draft is still
        // visible until its continuation runs. Only its explicit handoff unlocks.
        Some(submitted)
    }

    /// Retry or fork `session` (web's rail Retry/Fork): the next task gets it as
    /// parent. Returns the composer text: the fork briefing, or for a retry the
    /// original prompt (empty if it could not be read; see `derived.prompt_error`).
    /// Call after `load` for the same project.
    pub async fn derive(&self, kind: DerivedKind, session: ChatSession) -> String {
        let Some(task_id) = session.task.as_ref().map(|t| t.id.clone()).or(session.task_id.clone()) else { return String::new() };
        let label = session_label(&session);
        let task = session.task.as_ref();
        let derived = DerivedTask {
            kind,
            parent_session_id: session.id.clone(),
            parent_label: label.clone(),
            parent_task_id: task_id.clone(),
            parent_branch: task.and_then(|t| t.output_branch.clone()),
            error_message: if kind == DerivedKind::Retry { task.and_then(|t| t.error_message.clone()) } else { None },
            prompt_loading: kind == DerivedKind::Retry,
            prompt_error: None,
        };
        let mut project_id = String::new();
        self.update(|s| {
            project_id = s.project_id.clone();
            s.derived = Some(derived.clone());
        });
        if kind == DerivedKind::Fork {
            return fork_message(&label, &project_id, &session.id, &task_id);
        }
        let result: Result<serde_json::Value> = self.app.get(&format!("/api/projects/{}/tasks/{}", seg(&project_id), seg(&task_id))).await;
        let mut prompt = String::new();
        self.update(|s| {
            let Some(d) = s.derived.as_mut().filter(|d| d.parent_task_id == task_id && d.kind == DerivedKind::Retry) else { return };
            d.prompt_loading = false;
            match &result {
                Ok(task) => prompt = task["description"].as_str().unwrap_or_default().to_owned(),
                Err(e) => d.prompt_error = Some(UserError::from(e)),
            }
        });
        prompt
    }

    /// Back to an ordinary new task.
    pub fn cancel_derived(&self) {
        self.update(|s| s.derived = None);
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

/// `pattern` → `$1` for paired `open…close` markers, non-greedy, at least one char.
fn unwrap_pairs(text: &str, open: &str, close: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(start) = rest.find(open) {
        let after = &rest[start + open.len()..];
        // `.+?`: the inner text has at least one char, then the nearest close.
        let Some(first) = after.chars().next() else { break };
        let Some(end) = after[first.len_utf8()..].find(close).map(|e| e + first.len_utf8()) else { break };
        out.push_str(&rest[..start]);
        out.push_str(&after[..end]);
        rest = &after[end + close.len()..];
    }
    out.push_str(rest);
    out
}

/// Web's `stripMarkdown`: only double emphasis, so snake_case topics survive.
fn strip_markdown(text: &str) -> String {
    let mut s = unwrap_pairs(text, "**", "**");
    s = unwrap_pairs(&s, "__", "__");
    s = unwrap_pairs(&s, "~~", "~~");
    s = unwrap_pairs(&s, "`", "`");
    s = s
        .split('\n')
        .map(|line| {
            let hashes = line.chars().take_while(|c| *c == '#').count();
            let rest = &line[hashes..];
            if (1..=6).contains(&hashes) && rest.starts_with(char::is_whitespace) { rest.trim_start() } else { line }
        })
        .collect::<Vec<_>>()
        .join("\n");
    // [text](url) -> text
    let mut out = String::new();
    let mut rest = s.as_str();
    while let Some(open) = rest.find('[') {
        let after = &rest[open + 1..];
        match after.find("](").and_then(|mid| (mid > 0).then_some(mid)) {
            Some(mid) if after[mid + 2..].find(')').is_some_and(|c| c > 0) => {
                let close = after[mid + 2..].find(')').unwrap();
                out.push_str(&rest[..open]);
                out.push_str(&after[..mid]);
                rest = &after[mid + 2 + close + 1..];
            }
            _ => {
                out.push_str(&rest[..=open]);
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out.trim().to_owned()
}

/// Web's derived-session label: the topic as plain text, else "Chat 1a2b3c4d".
pub(crate) fn session_label(session: &ChatSession) -> String {
    session
        .topic
        .as_deref()
        .map(strip_markdown)
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| format!("Chat {}", session.id.chars().take(8).collect::<String>()))
}

/// Web's `buildForkMessage`, word for word, so the forked agent finds its parent.
#[uniffi::export]
pub fn fork_message(session_label: &str, project_id: &str, session_id: &str, task_id: &str) -> String {
    let mut ids = vec![
        format!("Previous session: \"{session_label}\""),
        format!("Parent project ID: {project_id}"),
        format!("Parent session ID: {session_id}"),
    ];
    if !task_id.is_empty() {
        ids.push(format!("Parent task ID: {task_id}"));
    }
    format!(
        "Use the SAM MCP tool sessions_read (methods messages and search) to review the previous session for full context about what was done and what needs to happen next.\nUse sessions_read method messages with the parent session ID below before relying on title or phrase search.\n\n{}\n\n",
        ids.join("\n")
    )
}

#[cfg(test)]
mod derived_tests {
    use super::*;

    #[test]
    fn fork_message_matches_web_template() {
        assert_eq!(
            fork_message("Fix login", "p", "s", "t"),
            "Use the SAM MCP tool sessions_read (methods messages and search) to review the previous session for full context about what was done and what needs to happen next.\nUse sessions_read method messages with the parent session ID below before relying on title or phrase search.\n\nPrevious session: \"Fix login\"\nParent project ID: p\nParent session ID: s\nParent task ID: t\n\n"
        );
        assert!(!fork_message("x", "p", "s", "").contains("Parent task ID"));
    }

    #[test]
    fn label_strips_markdown_or_falls_back_to_the_id() {
        let mut session: ChatSession = serde_json::from_value(serde_json::json!({"id": "1234567890", "topic": "## **Fix** `user_profile` [docs](https://x)"})).unwrap();
        assert_eq!(session_label(&session), "Fix user_profile docs");
        session.topic = None;
        assert_eq!(session_label(&session), "Chat 12345678");
    }
}
