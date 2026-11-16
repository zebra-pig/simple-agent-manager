//! Agent command discovery shared by native composers. Selection only edits the
//! draft; the existing task/prompt endpoint remains the explicit send boundary.
use crate::session::seg;
use serde::Deserialize;

#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct SlashCommand {
    pub name: String,
    pub description: String,
    #[serde(default)]
    pub agent_type: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct CommandsState {
    pub project_id: String,
    pub commands: Vec<SlashCommand>,
}

#[derive(Deserialize)]
struct CommandPage {
    commands: Vec<SlashCommand>,
}

observable!(CommandsViewModel, CommandsState, CommandsObserver);

#[uniffi::export(async_runtime = "tokio")]
impl CommandsViewModel {
    /// Read the same project command cache as web. A missing cache leaves the
    /// built-in agent registry available without interrupting chat or its draft.
    pub async fn load(&self, project_id: String) {
        self.update(|s| *s = CommandsState { project_id: project_id.clone(), commands: defaults() });
        let result = self.app.get::<CommandPage>(&format!("/api/projects/{}/cached-commands", seg(&project_id))).await;
        if let Ok(page) = result {
            self.update(|s| {
                if s.project_id == project_id {
                    s.commands = merge(page.commands);
                }
            });
        }
    }
}

fn defaults() -> Vec<SlashCommand> {
    [
        ("compact", "Compact conversation context"),
        ("cost", "Show token usage and cost"),
        ("doctor", "Check Claude Code setup health"),
        ("help", "Show available commands"),
        ("init", "Initialize CLAUDE.md project file"),
        ("login", "Switch accounts or auth method"),
        ("logout", "Log out of current session"),
        ("mcp", "Manage MCP servers"),
        ("memory", "Edit CLAUDE.md memory files"),
        ("model", "Switch AI model"),
        ("permissions", "View or edit tool permissions"),
        ("pr-comments", "View and address PR comments"),
        ("review", "Review code changes"),
        ("status", "Show session status"),
        ("vim", "Toggle vim keybindings"),
    ]
    .into_iter()
    .map(|(name, description)| SlashCommand { name: name.into(), description: description.into(), agent_type: Some("claude-code".into()) })
    .collect()
}

fn merge(cached: Vec<SlashCommand>) -> Vec<SlashCommand> {
    let mut commands = std::collections::BTreeMap::new();
    for mut command in defaults().into_iter().chain(cached) {
        command.name = command.name.trim_start_matches('/').to_string();
        // Names are inserted as a single token, never as a prompt or UI action.
        if command.name.is_empty() || command.name.chars().any(char::is_whitespace) {
            continue;
        }
        commands.insert(command.name.clone(), command);
    }
    commands.into_values().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cache_overrides_registry_and_retains_custom_skills() {
        let commands = merge(vec![
            SlashCommand { name: "/review".into(), description: "Repository review".into(), agent_type: Some("codex".into()) },
            SlashCommand { name: "do".into(), description: "Execute the task workflow".into(), agent_type: Some("codex".into()) },
            SlashCommand { name: "bad command".into(), description: "".into(), agent_type: None },
        ]);
        assert_eq!(commands.iter().filter(|c| c.name == "review").count(), 1);
        assert_eq!(commands.iter().find(|c| c.name == "review").unwrap().description, "Repository review");
        assert!(commands.iter().any(|c| c.name == "do"));
        assert!(!commands.iter().any(|c| c.name.contains(' ')));
    }
}
