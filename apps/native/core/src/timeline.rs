//! Turns a session's stored rows into what the chat shows, the way the web app
//! does (apps/web/src/components/project-message-view/types.ts and
//! tool-call-groups.ts):
//!
//! - streamed reply and thought chunks become whole messages;
//! - a tool call and its updates (same `toolCallId`) become one call with the
//!   latest status, title and files;
//! - a run of tool calls, with the thoughts between them, folds into one
//!   activity item, so the agent's prose isn't buried under 40 calls;
//! - plans are replaced in place by their latest version;
//! - rows SAM wrote (deliveries, task and wake reports) become notices.
//!
//! The core sends no wording: where the web app writes a fixed headline
//! ("Report from the workspace"), the notice says where it came from and the
//! shell writes the words.

use serde::Deserialize;
use serde_json::Value;

use crate::markdown::{self, Block};

/// A stored transcript row, as `GET /api/projects/:id/sessions/:sessionId` returns it.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Row {
    pub id: String,
    #[serde(default)]
    pub role: String,
    #[serde(default)]
    pub content: String,
    #[serde(default)]
    pub tool_metadata: Option<Value>,
    /// Unix milliseconds.
    #[serde(default)]
    pub created_at: i64,
    /// `system` for messages SAM sent on the user's behalf.
    #[serde(default)]
    pub origin: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ChatItem {
    /// Stable while the item grows (the id of its first row).
    pub id: String,
    /// Unix milliseconds of its first row.
    pub created_at: i64,
    pub content: ChatContent,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ChatContent {
    /// What the user sent.
    User {
        text: String,
    },
    /// The agent's reply: the raw Markdown (to copy) and its blocks (to show).
    Agent {
        text: String,
        blocks: Vec<Block>,
    },
    /// A thought on its own (thoughts between tool calls are in `Activity`).
    Thinking {
        text: String,
    },
    /// A run of tool calls and the thoughts between them.
    Activity {
        steps: Vec<ActivityStep>,
        summary: ActivitySummary,
    },
    Plan {
        entries: Vec<PlanEntry>,
    },
    Notice {
        notice: Notice,
    },
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ActivityStep {
    Tool { call: ToolCall },
    Thought { text: String },
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ActivitySummary {
    pub tool_count: u32,
    pub failed_count: u32,
    /// The agent is still in this run: it is the newest item and the agent is working.
    pub live: bool,
    /// The newest call's title while `live`, for "Running cargo test".
    pub live_title: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ToolCall {
    pub id: String,
    /// The agent's title for the call, workspace paths shortened. `None`:
    /// the shell names the call after its kind.
    pub title: Option<String>,
    /// The title is a command or code (it was in backticks): show it monospaced.
    pub title_is_code: bool,
    pub kind: ToolKind,
    pub status: ToolStatus,
    /// Files it touched, relative to the workspace where possible (`src/a.rs:12`).
    pub locations: Vec<String>,
    /// Its text output, when the row still has it (long output is cut).
    pub output: Option<String>,
}

/// ACP `ToolKind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ToolKind {
    Read,
    Edit,
    Delete,
    Move,
    Search,
    Execute,
    Think,
    Fetch,
    SwitchMode,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ToolStatus {
    Pending,
    Running,
    Completed,
    Failed,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PlanEntry {
    pub content: String,
    pub status: PlanStatus,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PlanStatus {
    Pending,
    InProgress,
    Completed,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Notice {
    pub source: NoticeSource,
    /// One line to show. `None` for `Workspace` and `Context`: the shell names those.
    pub headline: Option<String>,
    /// The rest, one tap away.
    pub detail: Option<String>,
    pub severity: NoticeSeverity,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NoticeSource {
    /// SAM's own words (task and wake reports, messages it delivered).
    Sam,
    /// Reported by the workspace runtime (which an agent can write to).
    Workspace,
    /// Context the chat's creator supplied.
    Context,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NoticeSeverity {
    Info,
    Success,
    /// SAM keeps amber for things waiting on the human.
    Warning,
    Error,
}

/// The longest tool output kept, in characters.
const OUTPUT_LIMIT: usize = 4000;

/// Builds the chat from rows sorted by time (equal timestamps keep server order).
/// `working`: the agent is mid-turn, so the newest activity is live.
pub(crate) fn build(mut rows: Vec<Row>, working: bool) -> Vec<ChatItem> {
    rows.sort_by_key(|r| r.created_at);
    let mut items: Vec<Positioned> = Vec::with_capacity(rows.len());
    let mut calls_by_id: std::collections::HashMap<String, usize> = Default::default();
    for row in rows {
        let meta = row.tool_metadata.as_ref().and_then(Value::as_object);
        match row.role.as_str() {
            "user" => {
                let notice = meta.and_then(sam_notice);
                let item = if let Some(notice) = notice {
                    Item::Notice(notice)
                } else if row.origin.as_deref() == Some("system") {
                    Item::Notice(first_line_notice(&row.content))
                } else {
                    Item::User(row.content)
                };
                items.push(item.at(row.id, row.created_at));
            }
            "assistant" => match items.last_mut() {
                Some(Positioned { item: Item::Agent(text), .. }) => text.push_str(&row.content),
                _ => items.push(Item::Agent(row.content).at(row.id, row.created_at)),
            },
            "thinking" => match items.last_mut() {
                Some(Positioned { item: Item::Thinking(text), .. }) => text.push_str(&row.content),
                _ => items.push(Item::Thinking(row.content).at(row.id, row.created_at)),
            },
            "plan" => {
                let Some(entries) = plan_entries(&row.content) else { continue };
                if let Some(existing) = items.iter_mut().find(|i| matches!(i.item, Item::Plan(_))) {
                    existing.item = Item::Plan(entries);
                } else {
                    items.push(Item::Plan(entries).at(row.id, row.created_at));
                }
            }
            "tool" => {
                let update = ToolUpdate::from(&row, meta);
                let existing = update.call_id.as_ref().and_then(|id| calls_by_id.get(id)).copied();
                match existing.and_then(|i| match &mut items[i].item {
                    Item::Tool(call) => Some(call),
                    _ => None,
                }) {
                    Some(call) => update.apply(call),
                    None => {
                        if let Some(id) = &update.call_id {
                            calls_by_id.insert(id.clone(), items.len());
                        }
                        let call = update.into_call(&row.id);
                        items.push(Item::Tool(call).at(row.id, row.created_at));
                    }
                }
            }
            "system" => items.push(Item::Notice(system_notice(&row.content, meta)).at(row.id, row.created_at)),
            // A role this build doesn't know: shown as plain text rather than dropped.
            _ if !row.content.trim().is_empty() => items.push(Item::Notice(first_line_notice(&row.content)).at(row.id, row.created_at)),
            _ => {}
        }
    }
    group(items, working)
}

/// Mid-build items, before tool calls are grouped.
enum Item {
    User(String),
    Agent(String),
    Thinking(String),
    Tool(ToolCall),
    Plan(Vec<PlanEntry>),
    Notice(Notice),
}

struct Positioned {
    id: String,
    created_at: i64,
    item: Item,
}

impl Item {
    fn at(self, id: String, created_at: i64) -> Positioned {
        Positioned { id, created_at, item: self }
    }
}

/// Folds each run of tool calls and thoughts into one activity item. A run
/// without a tool call stays as its thoughts.
fn group(items: Vec<Positioned>, working: bool) -> Vec<ChatItem> {
    let mut out = Vec::with_capacity(items.len());
    let mut run: Vec<Positioned> = Vec::new();
    for p in items {
        match p.item {
            Item::Tool(_) | Item::Thinking(_) => run.push(p),
            _ => {
                flush_run(&mut run, &mut out);
                out.push(finish(p));
            }
        }
    }
    flush_run(&mut run, &mut out);
    if working {
        if let Some(ChatItem { content: ChatContent::Activity { steps, summary }, .. }) = out.last_mut() {
            summary.live = true;
            summary.live_title = steps
                .iter()
                .rev()
                .find_map(|s| match s {
                    ActivityStep::Tool { call } => Some(call.title.clone()),
                    ActivityStep::Thought { .. } => None,
                })
                .flatten();
        }
    }
    out
}

fn flush_run(run: &mut Vec<Positioned>, out: &mut Vec<ChatItem>) {
    if run.is_empty() {
        return;
    }
    let run = std::mem::take(run);
    if !run.iter().any(|p| matches!(p.item, Item::Tool(_))) {
        out.extend(run.into_iter().map(finish));
        return;
    }
    let (id, created_at) = (run[0].id.clone(), run[0].created_at);
    let mut summary = ActivitySummary::default();
    let steps = run
        .into_iter()
        .filter_map(|p| match p.item {
            Item::Tool(call) => {
                summary.tool_count += 1;
                if call.status == ToolStatus::Failed {
                    summary.failed_count += 1;
                }
                Some(ActivityStep::Tool { call })
            }
            Item::Thinking(text) if !text.trim().is_empty() => Some(ActivityStep::Thought { text: text.trim().to_owned() }),
            _ => None,
        })
        .collect();
    out.push(ChatItem { id, created_at, content: ChatContent::Activity { steps, summary } });
}

fn finish(p: Positioned) -> ChatItem {
    let content = match p.item {
        Item::User(text) => ChatContent::User { text },
        Item::Agent(text) => ChatContent::Agent { blocks: markdown::parse(&text), text },
        Item::Thinking(text) => ChatContent::Thinking { text: text.trim().to_owned() },
        Item::Tool(call) => {
            let summary =
                ActivitySummary { tool_count: 1, failed_count: u32::from(call.status == ToolStatus::Failed), ..Default::default() };
            ChatContent::Activity { steps: vec![ActivityStep::Tool { call }], summary }
        }
        Item::Plan(entries) => ChatContent::Plan { entries },
        Item::Notice(notice) => ChatContent::Notice { notice },
    };
    ChatItem { id: p.id, created_at: p.created_at, content }
}

/// What one tool row says about its call; later rows only fill in what they carry.
struct ToolUpdate {
    call_id: Option<String>,
    title: Option<String>,
    kind: Option<ToolKind>,
    status: Option<ToolStatus>,
    locations: Vec<String>,
    output: Option<String>,
}

impl ToolUpdate {
    fn from(row: &Row, meta: Option<&serde_json::Map<String, Value>>) -> Self {
        let str_field = |key: &str| meta.and_then(|m| m.get(key)).and_then(Value::as_str).filter(|s| !s.is_empty());
        let locations = meta
            .and_then(|m| m.get("locations"))
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter_map(|l| {
                        let path = shorten_paths(l.get("path")?.as_str()?);
                        Some(match l.get("line").and_then(Value::as_u64) {
                            Some(line) => format!("{path}:{line}"),
                            None => path,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        Self {
            call_id: str_field("toolCallId").map(str::to_owned),
            title: str_field("title").map(str::to_owned),
            kind: str_field("kind").map(tool_kind).filter(|k| *k != ToolKind::Other),
            status: str_field("status").and_then(tool_status),
            locations,
            output: tool_output(&row.content, meta),
        }
    }

    fn apply(self, call: &mut ToolCall) {
        if let Some(title) = self.title {
            (call.title, call.title_is_code) = clean_title(&title);
        }
        if let Some(kind) = self.kind {
            call.kind = kind;
        }
        if let Some(status) = self.status {
            call.status = status;
        }
        if !self.locations.is_empty() {
            call.locations = self.locations;
        }
        if self.output.is_some() {
            call.output = self.output;
        }
    }

    fn into_call(self, row_id: &str) -> ToolCall {
        let (title, title_is_code) = self.title.as_deref().map(clean_title).unwrap_or((None, false));
        ToolCall {
            id: self.call_id.unwrap_or_else(|| row_id.to_owned()),
            title,
            title_is_code,
            kind: self.kind.unwrap_or(ToolKind::Other),
            // A row without a status is a finished call (the web app's rule).
            status: self.status.unwrap_or(ToolStatus::Completed),
            locations: self.locations,
            output: self.output,
        }
    }
}

fn tool_kind(kind: &str) -> ToolKind {
    match kind {
        "read" => ToolKind::Read,
        "edit" => ToolKind::Edit,
        "delete" => ToolKind::Delete,
        "move" => ToolKind::Move,
        "search" => ToolKind::Search,
        "execute" => ToolKind::Execute,
        "think" => ToolKind::Think,
        "fetch" => ToolKind::Fetch,
        "switch_mode" => ToolKind::SwitchMode,
        _ => ToolKind::Other,
    }
}

fn tool_status(status: &str) -> Option<ToolStatus> {
    Some(match status {
        "pending" => ToolStatus::Pending,
        "in_progress" => ToolStatus::Running,
        "completed" => ToolStatus::Completed,
        "failed" => ToolStatus::Failed,
        _ => return None,
    })
}

/// "`cargo test`" -> ("cargo test", code); workspace paths shortened.
fn clean_title(title: &str) -> (Option<String>, bool) {
    let title = title.trim();
    let (inner, code) = match title.strip_prefix('`').and_then(|t| t.strip_suffix('`')) {
        Some(inner) if !inner.contains('`') => (inner, true),
        _ => (title, false),
    };
    let inner = shorten_paths(inner);
    if inner.is_empty() {
        (None, false)
    } else {
        (Some(inner), code)
    }
}

/// Workspaces live at `/workspaces/<repo>/`; inside the chat that prefix is noise.
fn shorten_paths(text: &str) -> String {
    const ROOT: &str = "/workspaces/";
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find(ROOT) {
        out.push_str(&rest[..at]);
        let after = &rest[at + ROOT.len()..];
        // Only a path that starts there: not `/tmp/workspaces/...`.
        let at_boundary = rest[..at].chars().last().or(out.chars().last()).is_none_or(|c| !(c.is_alphanumeric() || "_./-~".contains(c)));
        match after.find('/') {
            // `/workspaces/repo/src/a.rs` -> `src/a.rs`; a bare `/workspaces/repo` stays.
            Some(slash) if at_boundary && slash > 0 && !after[..slash].contains(char::is_whitespace) => rest = &after[slash + 1..],
            _ => {
                out.push_str(ROOT);
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// The row's text output: its content, or the text parts of its structured
/// content; never the "(tool call)" placeholders.
fn tool_output(content: &str, meta: Option<&serde_json::Map<String, Value>>) -> Option<String> {
    let trimmed = content.trim();
    let text = if !trimmed.is_empty() && trimmed != "(tool call)" && trimmed != "(tool update)" {
        trimmed.to_owned()
    } else {
        let parts = meta?.get("content")?.as_array()?;
        let texts: Vec<&str> = parts
            .iter()
            .filter_map(|p| p.get("content").and_then(|c| c.get("text")).and_then(Value::as_str))
            .filter(|t| !t.trim().is_empty())
            .collect();
        if texts.is_empty() {
            return None;
        }
        texts.join("\n").trim().to_owned()
    };
    Some(cut(&text, OUTPUT_LIMIT))
}

fn cut(text: &str, max_chars: usize) -> String {
    match text.char_indices().nth(max_chars) {
        Some((at, _)) => format!("{}…", &text[..at]),
        None => text.to_owned(),
    }
}

fn plan_entries(content: &str) -> Option<Vec<PlanEntry>> {
    let list: Vec<Value> = serde_json::from_str(content).ok()?;
    let entries: Vec<PlanEntry> = list
        .iter()
        .filter_map(|e| {
            let content = e.get("content")?.as_str()?.trim();
            let status = match e.get("status").and_then(Value::as_str) {
                Some("in_progress") => PlanStatus::InProgress,
                Some("completed") => PlanStatus::Completed,
                _ => PlanStatus::Pending,
            };
            (!content.is_empty()).then(|| PlanEntry { content: content.to_owned(), status })
        })
        .collect();
    (!entries.is_empty()).then_some(entries)
}

/// The notice SAM wrote on a row only it writes: a durable delivery or an
/// orchestrator check-in (`samNoticeForMessage`).
fn sam_notice(meta: &serde_json::Map<String, Value>) -> Option<Notice> {
    let from_sam = meta.get("kind").and_then(Value::as_str) == Some("durable_prompt_delivery")
        || meta.get("source").and_then(Value::as_str) == Some("sam_orchestrator");
    let notice = meta.get("samNotice")?.as_object().filter(|_| from_sam)?;
    if notice.get("v").and_then(Value::as_u64) != Some(1) {
        return None;
    }
    let text = |key: &str| notice.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned);
    let headline = text("headline")?;
    let quote = notice.get("quote").and_then(|q| q.get("text")).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty());
    let detail = match (text("detail"), quote) {
        (Some(d), Some(q)) => Some(format!("{d}\n\n{q}")),
        (d, q) => d.or(q.map(str::to_owned)),
    };
    let severity = match notice.get("severity").and_then(Value::as_str) {
        Some("success") => NoticeSeverity::Success,
        Some("warning") => NoticeSeverity::Warning,
        Some("error") => NoticeSeverity::Error,
        _ => NoticeSeverity::Info,
    };
    Some(Notice { source: NoticeSource::Sam, headline: Some(headline), detail, severity })
}

/// A system row: a workspace report, the creator's context, or SAM's own
/// (`systemRowNoticeForMessage`).
fn system_notice(content: &str, meta: Option<&serde_json::Map<String, Value>>) -> Notice {
    let quoted = |source| Notice {
        source,
        headline: None,
        detail: Some(content.trim().to_owned()).filter(|s| !s.is_empty()),
        severity: NoticeSeverity::Info,
    };
    if meta.and_then(|m| m.get("runtimeReported")).and_then(Value::as_bool) == Some(true) {
        quoted(NoticeSource::Workspace)
    } else if meta.and_then(|m| m.get("source")).and_then(Value::as_str) == Some("context_summary") {
        quoted(NoticeSource::Context)
    } else {
        first_line_notice(content)
    }
}

/// The first line as the headline, everything as the detail when there is more.
fn first_line_notice(content: &str) -> Notice {
    let text = content.trim();
    let headline = text.lines().map(str::trim).find(|l| !l.is_empty()).map(str::to_owned);
    let detail = (text.lines().filter(|l| !l.trim().is_empty()).count() > 1).then(|| text.to_owned());
    Notice { source: NoticeSource::Sam, headline, detail, severity: NoticeSeverity::Info }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn row(id: &str, role: &str, content: &str, at: i64, meta: Value) -> Row {
        Row {
            id: id.into(),
            role: role.into(),
            content: content.into(),
            tool_metadata: (!meta.is_null()).then_some(meta),
            created_at: at,
            origin: None,
        }
    }

    fn kinds(items: &[ChatItem]) -> Vec<&'static str> {
        items
            .iter()
            .map(|i| match i.content {
                ChatContent::User { .. } => "user",
                ChatContent::Agent { .. } => "agent",
                ChatContent::Thinking { .. } => "thinking",
                ChatContent::Activity { .. } => "activity",
                ChatContent::Plan { .. } => "plan",
                ChatContent::Notice { .. } => "notice",
            })
            .collect()
    }

    #[test]
    fn merges_chunks_and_folds_tool_runs() {
        let rows = vec![
            row("u", "user", "Fix the build", 1, Value::Null),
            row("t1", "thinking", "Let me ", 2, Value::Null),
            row("t2", "thinking", "look.", 3, Value::Null),
            row(
                "c1",
                "tool",
                "(tool call)",
                4,
                json!({"toolCallId": "a", "title": "`cargo test`", "kind": "execute", "status": "in_progress"}),
            ),
            row(
                "c2",
                "tool",
                "(tool call)",
                5,
                json!({"toolCallId": "b", "title": "Read /workspaces/sam/src/lib.rs", "kind": "read", "status": "pending", "locations": [{"path": "/workspaces/sam/src/lib.rs", "line": 3}]}),
            ),
            row("c3", "tool", "test result: FAILED", 6, json!({"toolCallId": "a", "status": "failed"})),
            row("c4", "tool", "(tool update)", 7, json!({"toolCallId": "b", "status": "completed"})),
            row("a1", "assistant", "The test ", 8, Value::Null),
            row("a2", "assistant", "**fails**.", 9, Value::Null),
        ];
        let items = build(rows, false);
        assert_eq!(kinds(&items), ["user", "activity", "agent"]);

        let ChatContent::Activity { steps, summary } = &items[1].content else { unreachable!() };
        assert_eq!(items[1].id, "t1");
        assert_eq!(*summary, ActivitySummary { tool_count: 2, failed_count: 1, live: false, live_title: None });
        assert_eq!(steps[0], ActivityStep::Thought { text: "Let me look.".into() });
        assert_eq!(
            steps[1],
            ActivityStep::Tool {
                call: ToolCall {
                    id: "a".into(),
                    title: Some("cargo test".into()),
                    title_is_code: true,
                    kind: ToolKind::Execute,
                    status: ToolStatus::Failed,
                    locations: vec![],
                    output: Some("test result: FAILED".into()),
                }
            }
        );
        let ActivityStep::Tool { call } = &steps[2] else { unreachable!() };
        assert_eq!(call.title.as_deref(), Some("Read src/lib.rs"));
        assert_eq!(call.locations, ["src/lib.rs:3"]);
        assert_eq!(call.status, ToolStatus::Completed);
        assert_eq!(call.output, None);

        let ChatContent::Agent { text, blocks } = &items[2].content else { unreachable!() };
        assert_eq!(text, "The test **fails**.");
        assert_eq!(blocks.len(), 1);
    }

    #[test]
    fn live_run_and_lone_thoughts() {
        let rows = vec![
            row("t", "thinking", "Hmm", 1, Value::Null),
            row("a", "assistant", "Sure.", 2, Value::Null),
            row("c", "tool", "", 3, json!({"toolCallId": "x", "title": "Edit src/a.rs", "kind": "edit", "status": "in_progress"})),
        ];
        let items = build(rows.clone(), true);
        assert_eq!(kinds(&items), ["thinking", "agent", "activity"]);
        let ChatContent::Activity { summary, .. } = &items[2].content else { unreachable!() };
        assert!(summary.live);
        assert_eq!(summary.live_title.as_deref(), Some("Edit src/a.rs"));

        let items = build(rows, false);
        let ChatContent::Activity { summary, .. } = &items[2].content else { unreachable!() };
        assert!(!summary.live);
    }

    #[test]
    fn plans_replace_in_place_and_notices() {
        let rows = vec![
            row("p1", "plan", r#"[{"content":"Read","status":"in_progress"},{"content":"Fix","status":"pending"}]"#, 1, Value::Null),
            row("s", "system", "Task failed\nexit code 1", 2, Value::Null),
            row("w", "system", "disk full", 3, json!({"runtimeReported": true})),
            row(
                "d",
                "user",
                "raw text",
                4,
                json!({"kind": "durable_prompt_delivery", "samNotice": {"v": 1, "type": "subtask.completed", "headline": "Subtask done", "severity": "success", "refs": [], "quote": {"from": "Agent", "text": "All green"}}}),
            ),
            row("forged", "user", "hi", 5, json!({"samNotice": {"v": 1, "type": "x", "headline": "Forged", "refs": []}})),
            row("p2", "plan", r#"[{"content":"Read","status":"completed"},{"content":"Fix","status":"in_progress"}]"#, 6, Value::Null),
            row("bad", "plan", "not json", 7, Value::Null),
        ];
        let items = build(rows, false);
        assert_eq!(kinds(&items), ["plan", "notice", "notice", "notice", "user"]);
        assert_eq!(items[0].id, "p1");
        assert_eq!(
            items[0].content,
            ChatContent::Plan {
                entries: vec![
                    PlanEntry { content: "Read".into(), status: PlanStatus::Completed },
                    PlanEntry { content: "Fix".into(), status: PlanStatus::InProgress },
                ]
            }
        );
        assert_eq!(
            items[1].content,
            ChatContent::Notice {
                notice: Notice {
                    source: NoticeSource::Sam,
                    headline: Some("Task failed".into()),
                    detail: Some("Task failed\nexit code 1".into()),
                    severity: NoticeSeverity::Info,
                }
            }
        );
        let ChatContent::Notice { notice } = &items[2].content else { unreachable!() };
        assert_eq!(
            (notice.source, notice.headline.as_deref(), notice.detail.as_deref()),
            (NoticeSource::Workspace, None, Some("disk full"))
        );
        let ChatContent::Notice { notice } = &items[3].content else { unreachable!() };
        assert_eq!(
            (notice.headline.as_deref(), notice.detail.as_deref(), notice.severity),
            (Some("Subtask done"), Some("All green"), NoticeSeverity::Success)
        );
    }

    #[test]
    fn shortens_workspace_paths_only() {
        assert_eq!(shorten_paths("Read /workspaces/repo/a/b.rs and /workspaces/x"), "Read a/b.rs and /workspaces/x");
        assert_eq!(shorten_paths("/tmp/workspaces/"), "/tmp/workspaces/");
        assert_eq!(shorten_paths("/tmp/workspaces/repo/a"), "/tmp/workspaces/repo/a");
        assert_eq!(shorten_paths("(/workspaces/repo/a)"), "(a)");
        assert_eq!(clean_title("`a` and `b`"), (Some("`a` and `b`".into()), false));
        assert_eq!(cut("héllo", 2), "hé…");
    }
}
