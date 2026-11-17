//! Related work: the ideas, library files and pull requests linked to a chat,
//! from the same `/sessions/:id/links` read as web's Related drawer. Malformed
//! rows are dropped and totals repaired here, so both shells show the same list.
use crate::{error::UserError, session::seg};
use serde_json::Value;

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct LinkedWorkState {
    pub project_id: String,
    pub session_id: String,
    /// `None` until the first successful read; refreshes keep the last list.
    pub work: Option<LinkedWork>,
    pub loading: bool,
    pub error: Option<UserError>,
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct LinkedWork {
    pub ideas: Vec<LinkedIdea>,
    pub ideas_total: LinkedTotal,
    pub files: Vec<LinkedFile>,
    pub files_total: LinkedTotal,
    pub pull_requests: Vec<LinkedPullRequest>,
    pub pull_requests_total: LinkedTotal,
}

impl LinkedWork {
    pub fn is_empty(&self) -> bool {
        self.ideas.is_empty() && self.files.is_empty() && self.pull_requests.is_empty()
    }
}

/// A section's size. `lower_bound`: the server stopped counting, show "N+".
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Record)]
pub struct LinkedTotal {
    pub count: u32,
    pub lower_bound: bool,
    /// Only the most recent rows are listed.
    pub truncated: bool,
}

/// How a chat relates to an item, in web's display order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, uniffi::Enum)]
pub enum LinkRelation {
    WorksOn,
    Created,
    Edited,
    Opened,
    Uploaded,
    Replaced,
    Linked,
    Related,
    Discusses,
    Read,
    Viewed,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LinkedIdea {
    pub id: String,
    pub title: String,
    pub status: String,
    pub relations: Vec<LinkRelation>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LinkedFile {
    pub id: String,
    pub filename: String,
    pub directory: String,
    pub relations: Vec<LinkRelation>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PullRequestStatus {
    Open,
    Draft,
    Merged,
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ChecksStatus {
    Pending,
    Passed,
    Failing,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LinkedPullRequest {
    pub url: String,
    pub number: u32,
    pub title: Option<String>,
    /// `None` when GitHub state is unknown: no badge.
    pub status: Option<PullRequestStatus>,
    pub checks: Option<ChecksStatus>,
    /// The cached state may be out of date.
    pub stale: bool,
}

observable!(LinkedWorkViewModel, LinkedWorkState, LinkedWorkObserver);

#[uniffi::export(async_runtime = "tokio")]
impl LinkedWorkViewModel {
    pub async fn load(&self, project_id: String, session_id: String) {
        self.update(|s| {
            if s.project_id != project_id || s.session_id != session_id {
                *s = LinkedWorkState { project_id: project_id.clone(), session_id: session_id.clone(), ..Default::default() };
            }
            s.loading = true;
            s.error = None;
        });
        let result: crate::error::Result<Value> =
            self.app.get(&format!("/api/projects/{}/sessions/{}/links", seg(&project_id), seg(&session_id))).await;
        self.update(|s| {
            if s.project_id != project_id || s.session_id != session_id {
                return;
            }
            s.loading = false;
            match result {
                Ok(body) => s.work = Some(parse_linked_work(&body)),
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
    }
}

fn relation(name: &str) -> Option<LinkRelation> {
    Some(match name {
        "works_on" => LinkRelation::WorksOn,
        "created" => LinkRelation::Created,
        "edited" => LinkRelation::Edited,
        "opened" => LinkRelation::Opened,
        "uploaded" => LinkRelation::Uploaded,
        "replaced" => LinkRelation::Replaced,
        "linked" => LinkRelation::Linked,
        "related" => LinkRelation::Related,
        "discusses" => LinkRelation::Discusses,
        "read" => LinkRelation::Read,
        "viewed" => LinkRelation::Viewed,
        _ => return None,
    })
}

fn relations(v: &Value) -> Vec<LinkRelation> {
    let mut out: Vec<LinkRelation> = v.as_array().into_iter().flatten().filter_map(|r| r.as_str().and_then(relation)).collect();
    out.sort();
    out.dedup();
    out
}

fn text(v: &Value, key: &str) -> Option<String> {
    v[key].as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned)
}

fn list<T>(v: &Value, row: impl Fn(&Value) -> Option<T>) -> (Vec<T>, LinkedTotal) {
    let items: Vec<T> = v["items"].as_array().into_iter().flatten().filter_map(row).collect();
    let reported = v["total"].as_u64().unwrap_or(0).min(u32::MAX as u64) as u32;
    let total = LinkedTotal {
        count: reported.max(items.len() as u32),
        lower_bound: v["totalIsLowerBound"].as_bool().unwrap_or(false),
        truncated: v["truncated"].as_bool().unwrap_or(false),
    };
    (items, total)
}

fn pull_request(v: &Value) -> Option<LinkedPullRequest> {
    let url = text(v, "url")?;
    let number = v["number"].as_u64().filter(|n| *n > 0 && *n <= u32::MAX as u64)? as u32;
    let state = &v["state"];
    let status = match state["state"].as_str() {
        Some("open") if state["isDraft"].as_bool() == Some(true) => Some(PullRequestStatus::Draft),
        Some("open") => Some(PullRequestStatus::Open),
        Some("merged") => Some(PullRequestStatus::Merged),
        Some("closed") => Some(PullRequestStatus::Closed),
        _ => None,
    };
    let checks = status.and(match state["checksState"].as_str() {
        Some("pending") => Some(ChecksStatus::Pending),
        Some("success") => Some(ChecksStatus::Passed),
        Some("failure") => Some(ChecksStatus::Failing),
        _ => None,
    });
    Some(LinkedPullRequest {
        url,
        number,
        title: status.and(text(state, "title")),
        status,
        checks,
        stale: status.is_some() && state["stale"].as_bool().unwrap_or(false),
    })
}

/// Mirrors web's `normalizeSessionContext`: tolerate partial payloads.
pub fn parse_linked_work(v: &Value) -> LinkedWork {
    let (ideas, ideas_total) = list(&v["ideas"], |i| {
        Some(LinkedIdea {
            id: text(i, "ideaId")?,
            title: text(i, "title").unwrap_or_else(|| "Untitled idea".into()),
            status: text(i, "status").unwrap_or_default(),
            relations: relations(&i["relations"]),
        })
    });
    let (files, files_total) = list(&v["files"], |f| {
        Some(LinkedFile {
            id: text(f, "fileId")?,
            filename: text(f, "filename").unwrap_or_else(|| "Untitled file".into()),
            directory: text(f, "directory").unwrap_or_else(|| "/".into()),
            relations: relations(&f["relations"]),
        })
    });
    let (pull_requests, pull_requests_total) = list(&v["pullRequests"], pull_request);
    LinkedWork { ideas, ideas_total, files, files_total, pull_requests, pull_requests_total }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn drops_malformed_rows_and_repairs_totals() {
        let work = parse_linked_work(&json!({
            "ideas": {"items": [{"ideaId": "i1", "title": " ", "status": "ready", "relations": ["viewed", "works_on", "works_on", "bogus"]}, {"title": "no id"}], "total": 0, "truncated": false, "totalIsLowerBound": false},
            "files": {"items": [{"fileId": "f1", "filename": "plan.md", "relations": ["read"]}], "total": 40, "truncated": true, "totalIsLowerBound": true},
            "pullRequests": {"items": [
                {"url": "https://x/pr/1", "number": 1, "source": "task_output", "state": {"state": "open", "isDraft": true, "title": "Draft PR", "checksState": "failure", "stale": true}},
                {"url": "https://x/pr/2", "number": 2, "state": {"state": "weird"}},
                {"url": "https://x/pr/0", "number": 0},
                {"number": 3}
            ], "total": 1}
        }));
        assert_eq!(work.ideas.len(), 1);
        assert_eq!(work.ideas[0].title, "Untitled idea");
        assert_eq!(work.ideas[0].relations, vec![LinkRelation::WorksOn, LinkRelation::Viewed]);
        assert_eq!(work.ideas_total.count, 1, "total below item count is repaired");
        assert_eq!(work.files[0].directory, "/");
        assert_eq!(work.files_total, LinkedTotal { count: 40, lower_bound: true, truncated: true });
        assert_eq!(work.pull_requests.len(), 2);
        assert_eq!(work.pull_requests[0].status, Some(PullRequestStatus::Draft));
        assert_eq!(work.pull_requests[0].checks, Some(ChecksStatus::Failing));
        assert!(work.pull_requests[0].stale);
        assert_eq!(work.pull_requests[1].status, None, "unknown state shows no badge");
        assert_eq!(work.pull_requests[1].title, None);
        assert_eq!(work.pull_requests_total.count, 2);
    }

    #[test]
    fn missing_sections_are_empty() {
        assert!(parse_linked_work(&json!({})).is_empty());
    }
}
