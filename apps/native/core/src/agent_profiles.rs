//! Agent profiles: the saved setups (agent, model, effort, permissions, extra
//! instructions) a new chat starts with. The project screen lists them in its
//! composer, pre-selects one the way the web app does
//! (`selectProfileId` in apps/web/src/components/project-chat/profile-picker/model.ts),
//! and creates, edits and deletes them through the profile routes
//! (apps/api/src/routes/agent-profiles.ts).

use serde::{Deserialize, Serialize};

use crate::error::UserError;

/// `GET /api/projects/:id/agent-profiles` -> `items[]` (`AgentProfile` in
/// packages/shared/src/types/agent-settings.ts). Only what the app shows or edits.
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AgentProfile {
    pub id: String,
    /// `None` for the user's global profiles, which are edited elsewhere.
    #[serde(default)]
    pub project_id: Option<String>,
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    /// `claude-code`, `openai-codex`, ... (`AGENT_CATALOG`).
    #[serde(default)]
    pub agent_type: String,
    #[serde(default)]
    pub model: Option<String>,
    /// `AGENT_EFFORT_LEVELS`: auto, low, medium, high, xhigh, max.
    #[serde(default)]
    pub effort: Option<String>,
    /// `VALID_PERMISSION_MODES`; `None` uses the project's or user's setting.
    #[serde(default)]
    pub permission_mode: Option<String>,
    #[serde(default)]
    pub system_prompt_append: Option<String>,
    /// `task` (works and opens a pull request) or `conversation`; `None` lets SAM decide.
    #[serde(default)]
    pub task_mode: Option<String>,
    #[serde(default)]
    pub is_builtin: bool,
    /// Set by the core: the profile belongs to this project, so this app can edit
    /// and delete it (the server refuses global ones in a project's scope).
    #[serde(skip)]
    pub editable: bool,
}

#[derive(Deserialize)]
pub(crate) struct ProfileList {
    pub items: Vec<AgentProfile>,
}

/// `GET /api/projects/:id/agent-profiles/picker` (`ProfilePickerState`): the
/// user's own recent profiles (newest first) and the ones they hid.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PickerState {
    #[serde(default)]
    pub usage: Vec<ProfileUsage>,
    #[serde(default)]
    pub hidden_profile_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProfileUsage {
    pub profile_id: String,
}

/// `GET /api/agents` -> `agents[]`: the agents a profile can run.
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct AgentOption {
    pub id: String,
    pub name: String,
    /// The user has a key (or SAM's provider) for it.
    #[serde(default)]
    pub configured: bool,
}

#[derive(Deserialize)]
pub(crate) struct AgentList {
    pub agents: Vec<AgentOption>,
}

/// What the profile editor sends. Empty strings mean "not set": the profile
/// then uses the project's or the platform's default for that field.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ProfileDraft {
    pub name: String,
    pub description: String,
    pub agent_type: String,
    pub model: String,
    pub effort: String,
    pub permission_mode: String,
    pub system_prompt_append: String,
    pub task_mode: String,
}

impl ProfileDraft {
    /// Checks what the server would refuse anyway, so the editor can say why.
    pub(crate) fn body(&self) -> Result<ProfileBody, UserError> {
        let name = self.name.trim();
        if name.is_empty() {
            return Err(UserError::ProfileNameRequired);
        }
        let agent_type = self.agent_type.trim();
        let effort = set(&self.effort);
        if let Some(effort) = effort.as_deref().filter(|e| *e != "auto") {
            if !supported_efforts(agent_type.to_owned()).iter().any(|e| e == effort) {
                return Err(UserError::EffortNotSupported);
            }
        }
        Ok(ProfileBody {
            name: name.to_owned(),
            description: set(&self.description),
            agent_type: (!agent_type.is_empty()).then(|| agent_type.to_owned()),
            model: set(&self.model),
            effort,
            permission_mode: set(&self.permission_mode),
            system_prompt_append: set(&self.system_prompt_append),
            task_mode: set(&self.task_mode),
        })
    }
}

/// `POST` and `PUT .../agent-profiles[/:id]` (`CreateAgentProfileSchema`,
/// `UpdateAgentProfileSchema`). Optional fields go out as `null`, so clearing
/// one in the editor clears it on the server; the fields the app doesn't edit
/// (VM size, runtime, ...) are left out and keep their values.
#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProfileBody {
    pub name: String,
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_type: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub permission_mode: Option<String>,
    pub system_prompt_append: Option<String>,
    pub task_mode: Option<String>,
}

fn set(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_owned())
}

/// The editor's starting point for `profile`, or a new one (`None`).
#[uniffi::export]
pub fn profile_draft(profile: Option<AgentProfile>) -> ProfileDraft {
    let Some(p) = profile else {
        return ProfileDraft { agent_type: DEFAULT_AGENT_TYPE.to_owned(), ..Default::default() };
    };
    ProfileDraft {
        name: p.name,
        description: p.description.unwrap_or_default(),
        agent_type: p.agent_type,
        model: p.model.unwrap_or_default(),
        // `auto` is the default; the editor shows it as "not set".
        effort: p.effort.filter(|e| e != "auto").unwrap_or_default(),
        permission_mode: p.permission_mode.unwrap_or_default(),
        system_prompt_append: p.system_prompt_append.unwrap_or_default(),
        task_mode: p.task_mode.unwrap_or_default(),
    }
}

const DEFAULT_AGENT_TYPE: &str = "claude-code";

/// Effort levels `agent_type` takes besides `auto` (`getSupportedEffortsForAgent`
/// in packages/shared/src/types/agent-settings.ts). Empty: the agent has no
/// effort setting.
#[uniffi::export]
pub fn supported_efforts(agent_type: String) -> Vec<String> {
    let levels: &[&str] = match agent_type.as_str() {
        "claude-code" => &["low", "medium", "high", "xhigh", "max"],
        "openai-codex" => &["low", "medium", "high", "xhigh"],
        _ => &[],
    };
    levels.iter().map(|s| (*s).to_owned()).collect()
}

/// `VALID_PERMISSION_MODES` in packages/shared/src/constants/agent-settings.ts.
#[uniffi::export]
pub fn permission_modes() -> Vec<String> {
    ["default", "acceptEdits", "plan", "dontAsk", "bypassPermissions"].iter().map(|s| (*s).to_owned()).collect()
}

/// `TASK_MODES` in packages/shared/src/types/task.ts.
#[uniffi::export]
pub fn task_modes() -> Vec<String> {
    ["task", "conversation"].iter().map(|s| (*s).to_owned()).collect()
}

/// The profiles the picker offers: the user's recent ones first (newest first),
/// then the rest in the server's order; hidden ones left out, as on the web.
pub(crate) fn picker_order(project_id: &str, profiles: Vec<AgentProfile>, picker: &PickerState) -> Vec<AgentProfile> {
    let mut visible: Vec<AgentProfile> = profiles
        .into_iter()
        .filter(|p| !picker.hidden_profile_ids.contains(&p.id))
        .map(|mut p| {
            p.editable = p.project_id.as_deref() == Some(project_id);
            p
        })
        .collect();
    let rank = |p: &AgentProfile| picker.usage.iter().position(|u| u.profile_id == p.id).unwrap_or(usize::MAX);
    visible.sort_by_key(rank); // stable: the rest keep the server's order
    visible
}

/// The profile a new chat starts with: the current choice while it still
/// exists, else the most recent one, else the first. `None` without profiles
/// (the server then uses the project's defaults).
pub(crate) fn preselect(current: Option<&str>, profiles: &[AgentProfile]) -> Option<String> {
    current.filter(|id| profiles.iter().any(|p| p.id == *id)).map(str::to_owned).or_else(|| profiles.first().map(|p| p.id.clone()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(id: &str, project: Option<&str>) -> AgentProfile {
        serde_json::from_value(serde_json::json!({
            "id": id, "projectId": project, "userId": "u", "name": id, "agentType": "claude-code",
            "effort": "auto", "isBuiltin": false, "vmSizeOverride": null, "createdAt": "x"
        }))
        .unwrap()
    }

    #[test]
    fn orders_recent_first_and_drops_hidden() {
        let profiles = vec![profile("a", Some("p")), profile("b", None), profile("c", Some("p")), profile("d", Some("p"))];
        let picker: PickerState = serde_json::from_str(
            r#"{"usage": [{"profileId": "c", "lastUsedAt": "2", "chatCount": 1}, {"profileId": "gone", "lastUsedAt": "1", "chatCount": 1}],
                "hiddenProfileIds": ["d"], "usageWindowDays": 30}"#,
        )
        .unwrap();
        let ordered = picker_order("p", profiles, &picker);
        let ids: Vec<_> = ordered.iter().map(|p| (p.id.as_str(), p.editable)).collect();
        assert_eq!(ids, vec![("c", true), ("a", true), ("b", false)]);

        assert_eq!(preselect(None, &ordered).as_deref(), Some("c"));
        assert_eq!(preselect(Some("b"), &ordered).as_deref(), Some("b"));
        assert_eq!(preselect(Some("d"), &ordered).as_deref(), Some("c"));
        assert_eq!(preselect(Some("a"), &[]), None);
    }

    #[test]
    fn draft_round_trip_and_checks() {
        let mut p = profile("a", Some("p"));
        p.model = Some("claude-opus-5-5".into());
        let mut draft = profile_draft(Some(p));
        assert_eq!(draft.effort, "");
        assert_eq!(draft.model, "claude-opus-5-5");

        draft.model = "  ".into();
        draft.effort = "max".into();
        let body = serde_json::to_value(draft.body().unwrap()).unwrap();
        assert_eq!(
            body,
            serde_json::json!({
                "name": "a", "description": null, "agentType": "claude-code", "model": null,
                "effort": "max", "permissionMode": null, "systemPromptAppend": null, "taskMode": null
            })
        );

        draft.agent_type = "openai-codex".into();
        assert_eq!(draft.body(), Err(UserError::EffortNotSupported));
        draft.name = " ".into();
        assert_eq!(draft.body(), Err(UserError::ProfileNameRequired));
        assert_eq!(profile_draft(None).agent_type, "claude-code");
    }
}
