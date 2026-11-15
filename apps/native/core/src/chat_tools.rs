//! Read-only chat tools use the same session proxies and resource rollups as web.
//! Parsing files and unified diffs lives here, shared by all native shells.
use crate::{error::UserError, session::seg};
use serde::Deserialize;

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ChatToolsState {
    pub project_id: String,
    pub session_id: String,
    pub path: String,
    pub entries: Vec<FileEntry>,
    pub changes: Vec<GitChange>,
    pub lines: Vec<CodeLine>,
    pub points: Vec<ResourcePoint>,
    pub collection: String,
    pub omitted_chunks: u32,
    pub workspace: Option<WorkspaceInfo>,
    pub node: Option<NodeInfo>,
    pub limits: Vec<UsageWindow>,
    pub loading: bool,
    pub request_id: u64,
    pub error: Option<UserError>,
}
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
pub struct FileEntry {
    pub name: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub size: u64,
}
#[derive(Deserialize)]
struct FileList {
    path: String,
    entries: Vec<FileEntry>,
}
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct GitChange {
    pub path: String,
    pub status: String,
    #[serde(default)]
    pub old_path: Option<String>,
    #[serde(default)]
    pub staged: bool,
    #[serde(default)]
    pub untracked: bool,
}
#[derive(Deserialize)]
struct GitStatus {
    staged: Vec<GitChange>,
    unstaged: Vec<GitChange>,
    untracked: Vec<GitChange>,
}
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum CodeKind {
    Context,
    Added,
    Removed,
    Header,
}
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CodeLine {
    pub text: String,
    pub old_number: Option<u32>,
    pub new_number: Option<u32>,
    pub kind: CodeKind,
}
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ResourcePoint {
    pub time: i64,
    pub cpu_cores: Option<f64>,
    pub memory_bytes: Option<f64>,
    pub read_bytes: Option<f64>,
    pub write_bytes: Option<f64>,
    pub run_id: String,
}
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceInfo {
    pub id: String,
    pub name: String,
    pub status: String,
    pub branch: String,
    #[serde(default)]
    pub node_id: Option<String>,
    #[serde(default)]
    pub vm_location: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct NodeInfo {
    pub id: String,
    pub name: String,
    pub status: String,
    #[serde(default)]
    pub health_status: Option<String>,
    #[serde(default)]
    pub cloud_provider: Option<String>,
    #[serde(default)]
    pub provider_instance_type: Option<String>,
    #[serde(default)]
    pub provider_instance_vcpu_count: Option<u32>,
    #[serde(default)]
    pub provider_instance_memory_mb: Option<u64>,
}
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct UsageWindow {
    pub provider: String,
    pub window_type: String,
    pub status: String,
    pub utilization_percent: Option<f64>,
    pub remaining_amount: Option<f64>,
    pub limit_amount: Option<f64>,
    pub resets_at: Option<i64>,
    pub observed_at: i64,
    #[serde(default)]
    pub reset_elapsed: bool,
}
#[derive(Deserialize)]
struct Limits {
    #[serde(default)]
    credentials: Vec<Credential>,
}
#[derive(Deserialize)]
struct Credential {
    #[serde(default)]
    windows: Vec<UsageWindow>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Timeline {
    collection: String,
    #[serde(default)]
    omitted_chunk_count: u32,
    chunks: Vec<Chunk>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Chunk {
    workspace_id: String,
    rollup: Option<Rollup>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Rollup {
    start: Vec<i64>,
    cpu_mean_cores: Vec<Option<f64>>,
    memory_mean_bytes: Vec<Option<f64>>,
    io_read_bytes: Vec<Option<f64>>,
    io_write_bytes: Vec<Option<f64>>,
}

// Private identity keeps refreshes visible without showing another file on failed navigation.
observable!(ChatToolsViewModel, ChatToolsState, ChatToolsObserver, Option<(String, bool, bool)>);

#[uniffi::export(async_runtime = "tokio")]
impl ChatToolsViewModel {
    pub fn load(&self, project_id: String, session_id: String) {
        self.update_data(|s, source| {
            *source = None;
            *s = ChatToolsState { project_id, session_id, request_id: s.request_id + 1, path: ".".into(), ..Default::default() }
        });
    }
    pub async fn browse(&self, path: String) {
        let state = self.begin();
        let result: crate::error::Result<FileList> = self.app.get(&format!("{}/files/list?path={}", base(&state), seg(&path))).await;
        self.finish(&state, |s| match result {
            Ok(mut list) => {
                list.entries.sort_by_key(|e| (e.kind != "dir", e.name.to_lowercase()));
                s.path = list.path;
                s.entries = list.entries;
                s.lines.clear();
            }
            Err(e) => s.error = Some(UserError::from(&e)),
        });
    }
    pub async fn git_status(&self) {
        let state = self.begin();
        let result: crate::error::Result<GitStatus> = self.app.get(&format!("{}/git/status", base(&state))).await;
        self.finish(&state, |s| match result {
            Ok(mut git) => {
                for c in &mut git.staged {
                    c.staged = true;
                }
                for c in &mut git.untracked {
                    c.untracked = true;
                }
                s.changes = git.staged.into_iter().chain(git.unstaged).chain(git.untracked).collect();
                s.lines.clear();
            }
            Err(e) => s.error = Some(UserError::from(&e)),
        });
    }
    pub async fn open_file(&self, path: String, diff: bool, staged: bool) {
        self.update_data(|s, source| {
            let key = (path.clone(), diff, staged);
            if source.as_ref() != Some(&key) {
                s.lines.clear();
            }
            *source = Some(key);
        });
        let state = self.begin();
        let endpoint =
            if diff { format!("git/diff?path={}&staged={staged}", seg(&path)) } else { format!("files/view?path={}", seg(&path)) };
        let result: crate::error::Result<serde_json::Value> = self.app.get(&format!("{}/{}", base(&state), endpoint)).await;
        self.finish(&state, |s| match result {
            Ok(body) => {
                let key = if diff { "diff" } else { "content" };
                if let Some(text) = body[key].as_str() {
                    s.lines = code_lines(text, diff);
                } else {
                    s.error = Some(UserError::Unexpected { detail: "file response missing text".into() });
                }
            }
            Err(e) => s.error = Some(UserError::from(&e)),
        });
    }
    pub async fn resources(&self) {
        let state = self.begin();
        let result: crate::error::Result<Timeline> = self.app.get(&format!("{}/resource-timeline", base(&state))).await;
        self.finish(&state, |s| match result {
            Ok(timeline) => {
                s.collection = timeline.collection;
                s.omitted_chunks = timeline.omitted_chunk_count;
                s.points = timeline
                    .chunks
                    .into_iter()
                    .flat_map(|c| {
                        let run = c.workspace_id;
                        c.rollup.into_iter().flat_map(move |r| {
                            (0..r.start.len())
                                .map(|i| ResourcePoint {
                                    time: r.start[i],
                                    cpu_cores: finite(r.cpu_mean_cores.get(i)),
                                    memory_bytes: finite(r.memory_mean_bytes.get(i)),
                                    read_bytes: finite(r.io_read_bytes.get(i)),
                                    write_bytes: finite(r.io_write_bytes.get(i)),
                                    run_id: run.clone(),
                                })
                                .collect::<Vec<_>>()
                        })
                    })
                    .collect();
                s.points.sort_by_key(|p| p.time);
            }
            Err(e) => s.error = Some(UserError::from(&e)),
        });
    }
    pub async fn details(&self, workspace_id: Option<String>, agent_session_id: Option<String>) {
        let state = self.begin();
        // Usage is scoped to this agent's actual credential, never another account's balance.
        let limits: crate::error::Result<Limits> = if let Some(id) = agent_session_id {
            self.app.get(&format!("/api/projects/{}/credential-limits?agentSessionId={}", seg(&state.project_id), seg(&id))).await
        } else {
            Ok(Limits { credentials: vec![] })
        };
        let workspace: crate::error::Result<Option<WorkspaceInfo>> =
            if let Some(id) = workspace_id { self.app.get(&format!("/api/workspaces/{}", seg(&id))).await.map(Some) } else { Ok(None) };
        let node: crate::error::Result<Option<NodeInfo>> = if let Ok(Some(w)) = &workspace {
            if let Some(id) = &w.node_id {
                self.app.get(&format!("/api/nodes/{}", seg(id))).await.map(Some)
            } else {
                Ok(None)
            }
        } else {
            Ok(None)
        };
        self.finish(&state, |s| {
            match limits {
                Ok(l) => s.limits = l.credentials.into_iter().flat_map(|c| c.windows).collect(),
                Err(e) => s.error = Some(UserError::from(&e)),
            }
            match workspace {
                Ok(w) => s.workspace = w,
                Err(e) => s.error = Some(UserError::from(&e)),
            }
            match node {
                Ok(n) => s.node = n,
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
    }
}
impl ChatToolsViewModel {
    fn begin(&self) -> ChatToolsState {
        self.update(|s| {
            s.loading = true;
            s.error = None;
            s.request_id += 1;
        });
        self.state()
    }
    fn finish(&self, request: &ChatToolsState, f: impl FnOnce(&mut ChatToolsState)) {
        self.update(|s| {
            if s.project_id == request.project_id && s.session_id == request.session_id && s.request_id == request.request_id {
                s.loading = false;
                f(s);
            }
        });
    }
}
fn base(s: &ChatToolsState) -> String {
    format!("/api/projects/{}/sessions/{}", seg(&s.project_id), seg(&s.session_id))
}
fn finite(v: Option<&Option<f64>>) -> Option<f64> {
    v.copied().flatten().filter(|n| n.is_finite() && *n >= 0.0)
}

/// Line numbers are parsed once in Rust, including hunk offsets and no-newline markers.
pub fn code_lines(text: &str, diff: bool) -> Vec<CodeLine> {
    let (mut old, mut new) = (0, 0);
    let mut in_hunk = false;
    text.lines()
        .enumerate()
        .map(|(i, text)| {
            if !diff {
                return CodeLine { text: text.into(), old_number: None, new_number: Some(i as u32 + 1), kind: CodeKind::Context };
            }
            let kind = if text.starts_with("@@ ") {
                in_hunk = true;
                let mut parts = text.split_whitespace();
                parts.next();
                old = parts.next().and_then(|s| s.trim_start_matches('-').split(',').next()?.parse().ok()).unwrap_or(0);
                new = parts.next().and_then(|s| s.trim_start_matches('+').split(',').next()?.parse().ok()).unwrap_or(0);
                CodeKind::Header
            } else if !in_hunk || text.starts_with("diff ") || text.starts_with('\\') {
                if text.starts_with("diff ") {
                    in_hunk = false;
                }
                CodeKind::Header
            } else if text.starts_with('+') {
                CodeKind::Added
            } else if text.starts_with('-') {
                CodeKind::Removed
            } else {
                CodeKind::Context
            };
            let old_number = matches!(kind, CodeKind::Context | CodeKind::Removed).then_some(old);
            let new_number = matches!(kind, CodeKind::Context | CodeKind::Added).then_some(new);
            if old_number.is_some() {
                old += 1;
            }
            if new_number.is_some() {
                new += 1;
            }
            CodeLine { text: text.into(), old_number, new_number, kind }
        })
        .collect()
}
