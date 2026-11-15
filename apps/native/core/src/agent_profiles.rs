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
    /// `cf-container` (instant container) or `vm`; `None` lets SAM decide.
    #[serde(default)]
    pub runtime: Option<String>,
    /// The older fixed machine size (small, medium, large). Newer profiles use
    /// `resource_requirements_json` instead.
    #[serde(default)]
    pub vm_size_override: Option<String>,
    /// The minimum machine as JSON (`ResourceRequirements`: minVcpu,
    /// minMemoryGb, minDiskGb, exclusiveNode).
    #[serde(default)]
    pub resource_requirements_json: Option<String>,
    /// `full` or `lightweight`.
    #[serde(default)]
    pub workspace_profile: Option<String>,
    /// Which `.devcontainer/<name>` to use; `None` auto-detects.
    #[serde(default)]
    pub devcontainer_config_name: Option<String>,
    #[serde(default)]
    pub max_turns: Option<u32>,
    #[serde(default)]
    pub timeout_minutes: Option<u32>,
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
    /// `vm` or `cf-container`. An instant container has no machine settings:
    /// saving one clears them and uses a lightweight workspace, as the web does.
    pub runtime: String,
    /// The minimum machine. Numbers as typed (`2`, `3.5`); empty inherits.
    pub min_vcpu: String,
    pub min_memory_gb: String,
    pub min_disk_gb: String,
    /// A node of its own: `None` inherits, `Some(false)` overrides a project
    /// default of `true`.
    pub exclusive_node: Option<bool>,
    /// The older fixed size some profiles still carry; set it to empty to clear it.
    pub legacy_vm_size: String,
    /// `full` or `lightweight`.
    pub workspace_profile: String,
    /// `.devcontainer/<name>`; empty auto-detects. Not used by lightweight workspaces.
    pub devcontainer_config_name: String,
    /// Whole numbers as typed; empty inherits.
    pub max_turns: String,
    pub timeout_minutes: String,
    /// The stored requirements as loaded, so keys this app doesn't edit survive
    /// a save. The shell passes it back unchanged.
    pub stored_resources: String,
}

/// The number fields of the profile editor, for `UserError::InvalidProfileNumber`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ProfileNumberField {
    MinVcpu,
    MinMemoryGb,
    MinDiskGb,
    MaxTurns,
    TimeoutMinutes,
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
        let runtime = set(&self.runtime);
        let instant = runtime.as_deref() == Some(INSTANT_RUNTIME);
        let workspace_profile = if instant { Some("lightweight".to_owned()) } else { set(&self.workspace_profile) };
        let lightweight = workspace_profile.as_deref() == Some("lightweight");
        let resources = self.resources()?;
        Ok(ProfileBody {
            name: name.to_owned(),
            description: set(&self.description),
            agent_type: (!agent_type.is_empty()).then(|| agent_type.to_owned()),
            model: set(&self.model),
            effort,
            permission_mode: set(&self.permission_mode),
            system_prompt_append: set(&self.system_prompt_append),
            task_mode: set(&self.task_mode),
            max_turns: whole(&self.max_turns, ProfileNumberField::MaxTurns)?,
            timeout_minutes: whole(&self.timeout_minutes, ProfileNumberField::TimeoutMinutes)?,
            vm_size_override: if instant { None } else { set(&self.legacy_vm_size) },
            resource_requirements_json: if instant { None } else { resources },
            devcontainer_config_name: if lightweight { None } else { set(&self.devcontainer_config_name) },
            workspace_profile,
            runtime,
        })
    }

    /// `resourceRequirementsJson`: the stored keys this app doesn't edit, plus
    /// the ones it does. `None` when nothing is set. Retired keys are dropped,
    /// as on the web (`RETIRED_FIELDS`).
    fn resources(&self) -> Result<Option<String>, UserError> {
        use serde_json::{Map, Value};
        let mut map: Map<String, Value> = serde_json::from_str(&self.stored_resources).unwrap_or_default();
        for key in ["minVcpu", "minMemoryGb", "minDiskGb", "exclusiveNode", "maxCoTenants"] {
            map.remove(key);
        }
        let fields = [
            ("minVcpu", &self.min_vcpu, ProfileNumberField::MinVcpu, false),
            ("minMemoryGb", &self.min_memory_gb, ProfileNumberField::MinMemoryGb, false),
            ("minDiskGb", &self.min_disk_gb, ProfileNumberField::MinDiskGb, true),
        ];
        for (key, value, field, zero_ok) in fields {
            if let Some(n) = decimal(value, field, zero_ok)? {
                map.insert(key.to_owned(), n);
            }
        }
        if let Some(exclusive) = self.exclusive_node {
            map.insert("exclusiveNode".to_owned(), Value::Bool(exclusive));
        }
        Ok((!map.is_empty()).then(|| Value::Object(map).to_string()))
    }
}

/// The runtime without a VM (`AGENT_PROFILE_RUNTIMES`).
const INSTANT_RUNTIME: &str = "cf-container";

/// A positive whole number, or `None` when empty.
fn whole(value: &str, field: ProfileNumberField) -> Result<Option<u32>, UserError> {
    let Some(value) = set(value) else { return Ok(None) };
    match value.parse::<u32>() {
        Ok(n) if n > 0 => Ok(Some(n)),
        _ => Err(UserError::InvalidProfileNumber { field }),
    }
}

/// A positive (or, with `zero_ok`, non-negative) number, accepting a decimal
/// comma; whole values go out as integers (`2`, not `2.0`).
fn decimal(value: &str, field: ProfileNumberField, zero_ok: bool) -> Result<Option<serde_json::Value>, UserError> {
    let Some(value) = set(value) else { return Ok(None) };
    let n: f64 = value.replace(',', ".").parse().map_err(|_| UserError::InvalidProfileNumber { field })?;
    if !n.is_finite() || n < 0.0 || (n == 0.0 && !zero_ok) {
        return Err(UserError::InvalidProfileNumber { field });
    }
    let number = if n.fract() == 0.0 && n <= u32::MAX as f64 {
        serde_json::Number::from(n as u64)
    } else {
        serde_json::Number::from_f64(n).ok_or(UserError::InvalidProfileNumber { field })?
    };
    Ok(Some(serde_json::Value::Number(number)))
}

/// `POST` and `PUT .../agent-profiles[/:id]` (`CreateAgentProfileSchema`,
/// `UpdateAgentProfileSchema`). Optional fields go out as `null`, so clearing
/// one in the editor clears it on the server; the fields the app doesn't edit
/// (provider, location, GitHub CLI policy, AI models) are left out and keep
/// their values.
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
    pub max_turns: Option<u32>,
    pub timeout_minutes: Option<u32>,
    pub runtime: Option<String>,
    pub vm_size_override: Option<String>,
    pub resource_requirements_json: Option<String>,
    pub workspace_profile: Option<String>,
    pub devcontainer_config_name: Option<String>,
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
    let resources: serde_json::Map<String, serde_json::Value> =
        p.resource_requirements_json.as_deref().and_then(|j| serde_json::from_str(j).ok()).unwrap_or_default();
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
        min_vcpu: resource_text(&resources, "minVcpu"),
        min_memory_gb: resource_text(&resources, "minMemoryGb"),
        min_disk_gb: resource_text(&resources, "minDiskGb"),
        exclusive_node: resources.get("exclusiveNode").and_then(serde_json::Value::as_bool),
        stored_resources: p.resource_requirements_json.unwrap_or_default(),
        legacy_vm_size: p.vm_size_override.unwrap_or_default(),
        // An instant container always has a lightweight workspace (see `body`).
        workspace_profile: if p.runtime.as_deref() == Some(INSTANT_RUNTIME) {
            "lightweight".to_owned()
        } else {
            p.workspace_profile.unwrap_or_default()
        },
        devcontainer_config_name: p.devcontainer_config_name.unwrap_or_default(),
        runtime: p.runtime.unwrap_or_default(),
        max_turns: p.max_turns.map(|n| n.to_string()).unwrap_or_default(),
        timeout_minutes: p.timeout_minutes.map(|n| n.to_string()).unwrap_or_default(),
    }
}

/// A number from the stored requirements, as the editor shows it (`2`, `3.5`).
fn resource_text(resources: &serde_json::Map<String, serde_json::Value>, key: &str) -> String {
    match resources.get(key) {
        Some(serde_json::Value::Number(n)) => n.to_string(),
        _ => String::new(),
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

/// `AGENT_PROFILE_RUNTIMES` in packages/shared/src/types/agent-settings.ts.
#[uniffi::export]
pub fn profile_runtimes() -> Vec<String> {
    ["vm", INSTANT_RUNTIME].iter().map(|s| (*s).to_owned()).collect()
}

/// `WorkspaceProfileSchema`: a full devcontainer or a lightweight workspace.
#[uniffi::export]
pub fn workspace_profiles() -> Vec<String> {
    ["full", "lightweight"].iter().map(|s| (*s).to_owned()).collect()
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
                "effort": "max", "permissionMode": null, "systemPromptAppend": null, "taskMode": null,
                "maxTurns": null, "timeoutMinutes": null, "runtime": null, "vmSizeOverride": null,
                "resourceRequirementsJson": null, "workspaceProfile": null, "devcontainerConfigName": null
            })
        );

        draft.agent_type = "openai-codex".into();
        assert_eq!(draft.body(), Err(UserError::EffortNotSupported));
        draft.name = " ".into();
        assert_eq!(draft.body(), Err(UserError::ProfileNameRequired));
        assert_eq!(profile_draft(None).agent_type, "claude-code");
    }

    #[test]
    fn machine_settings() {
        let mut p = profile("a", Some("p"));
        p.vm_size_override = Some("large".into());
        p.resource_requirements_json =
            Some(r#"{"minVcpu": 4, "minMemoryGb": 7.5, "exclusiveNode": false, "maxCoTenants": 2, "future": "x"}"#.into());
        p.max_turns = Some(40);
        let mut draft = profile_draft(Some(p));
        assert_eq!((draft.min_vcpu.as_str(), draft.min_memory_gb.as_str(), draft.min_disk_gb.as_str()), ("4", "7.5", ""));
        assert_eq!(draft.exclusive_node, Some(false));
        assert_eq!((draft.legacy_vm_size.as_str(), draft.max_turns.as_str()), ("large", "40"));

        // Edited keys change, unknown ones stay, retired ones go.
        draft.min_vcpu = "8".into();
        draft.min_disk_gb = "0".into();
        draft.min_memory_gb = "".into();
        draft.exclusive_node = Some(true);
        draft.legacy_vm_size = "".into();
        draft.workspace_profile = "lightweight".into();
        draft.devcontainer_config_name = "python".into();
        let body = draft.body().unwrap();
        let resources: serde_json::Value = serde_json::from_str(body.resource_requirements_json.as_deref().unwrap()).unwrap();
        assert_eq!(resources, serde_json::json!({"minVcpu": 8, "minDiskGb": 0, "exclusiveNode": true, "future": "x"}));
        assert_eq!(body.vm_size_override, None);
        assert_eq!(body.devcontainer_config_name, None); // lightweight has no devcontainer
        assert_eq!(body.max_turns, Some(40));

        // An instant container drops the machine and uses a lightweight workspace.
        draft.runtime = "cf-container".into();
        draft.workspace_profile = "full".into();
        let body = draft.body().unwrap();
        assert_eq!((body.resource_requirements_json, body.workspace_profile.as_deref()), (None, Some("lightweight")));

        // Numbers are checked before anything is sent.
        draft.runtime = "vm".into();
        draft.min_memory_gb = "3,5".into();
        assert!(draft.body().unwrap().resource_requirements_json.unwrap().contains("\"minMemoryGb\":3.5"));
        for (field, value, which) in [
            ("vcpu", "0", ProfileNumberField::MinVcpu),
            ("disk", "-1", ProfileNumberField::MinDiskGb),
            ("turns", "1.5", ProfileNumberField::MaxTurns),
            ("timeout", "soon", ProfileNumberField::TimeoutMinutes),
        ] {
            let mut d = draft.clone();
            match field {
                "vcpu" => d.min_vcpu = value.into(),
                "disk" => d.min_disk_gb = value.into(),
                "turns" => d.max_turns = value.into(),
                _ => d.timeout_minutes = value.into(),
            }
            assert_eq!(d.body(), Err(UserError::InvalidProfileNumber { field: which }));
        }
    }
}
