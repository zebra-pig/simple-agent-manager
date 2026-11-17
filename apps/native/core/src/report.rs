//! "Report an issue" from a chat, on web's `/api/report-issue` route. Technical
//! references are only attached with the reporter's explicit consent.
use crate::error::UserError;
use serde::Serialize;
use serde_json::Value;

pub const REPORT_TITLE_MAX: u32 = 200;
pub const REPORT_DESCRIPTION_MAX: u32 = 5000;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ReportRefs {
    pub session_id: Option<String>,
    pub task_id: Option<String>,
    pub node_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SubmittedReport {
    pub id: String,
    pub status: String,
    /// The server's own confirmation, written for people.
    pub message: String,
    /// `sessionId`, `taskId`, `nodeId`… that were attached.
    pub attached: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ReportState {
    pub submitting: bool,
    pub submitted: Option<SubmittedReport>,
    pub error: Option<UserError>,
}

observable!(ReportViewModel, ReportState, ReportObserver);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ReportBody<'a> {
    title: &'a str,
    description: &'a str,
    consent_to_attach_refs: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    refs: Option<Value>,
}

/// The references worth offering: empty values are left out.
#[uniffi::export]
pub fn report_refs_present(refs: &ReportRefs) -> Vec<String> {
    let mut keys = vec![];
    for (key, value) in [("sessionId", &refs.session_id), ("taskId", &refs.task_id), ("nodeId", &refs.node_id)] {
        if value.as_deref().is_some_and(|v| !v.trim().is_empty()) {
            keys.push(key.to_owned());
        }
    }
    keys
}

#[uniffi::export(async_runtime = "tokio")]
impl ReportViewModel {
    pub fn reset(&self) {
        self.update(|s| *s = ReportState::default());
    }

    pub async fn submit(&self, title: String, description: String, attach_refs: bool, refs: ReportRefs) -> bool {
        let title = title.trim().to_owned();
        let description = description.trim().to_owned();
        if title.is_empty()
            || description.is_empty()
            || title.chars().count() > REPORT_TITLE_MAX as usize
            || description.chars().count() > REPORT_DESCRIPTION_MAX as usize
        {
            return false;
        }
        let mut claimed = false;
        self.update(|s| {
            if !s.submitting && s.submitted.is_none() {
                s.submitting = true;
                s.error = None;
                claimed = true;
            }
        });
        if !claimed {
            return false;
        }
        let refs = attach_refs.then(|| {
            let mut map = serde_json::Map::new();
            for (key, value) in [("sessionId", refs.session_id), ("taskId", refs.task_id), ("nodeId", refs.node_id)] {
                if let Some(v) = value.map(|v| v.trim().to_owned()).filter(|v| !v.is_empty()) {
                    map.insert(key.into(), v.into());
                }
            }
            Value::Object(map)
        });
        let body = ReportBody { title: &title, description: &description, consent_to_attach_refs: attach_refs, refs };
        let result: crate::error::Result<Value> = self.app.post("/api/report-issue", &body).await;
        let ok = result.is_ok();
        self.update(|s| {
            s.submitting = false;
            match result {
                Ok(v) => {
                    s.submitted = Some(SubmittedReport {
                        id: v["ideaId"].as_str().unwrap_or_default().to_owned(),
                        status: v["status"].as_str().unwrap_or_default().to_owned(),
                        message: v["message"].as_str().unwrap_or_default().to_owned(),
                        attached: v["attachedRefKeys"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(|k| k.as_str().map(str::to_owned))
                            .collect(),
                    })
                }
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
        ok
    }
}
