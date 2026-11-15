//! Inbox and authoritative request forms shared by both native shells.
use crate::{session::seg, UserError};
use serde::Deserialize;

#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct Notification {
    pub id: String,
    pub project_id: Option<String>,
    pub session_id: Option<String>,
    pub title: String,
    pub body: Option<String>,
    #[serde(rename = "type")]
    pub kind: String,
    pub action_url: Option<String>,
    pub read_at: Option<String>,
    #[serde(default, skip_deserializing)]
    pub request_id: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Page {
    notifications: Vec<serde_json::Value>,
    next_cursor: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct NotificationsState {
    pub items: Vec<Notification>,
    pub loading: bool,
    pub error: Option<UserError>,
}
observable!(NotificationsViewModel, NotificationsState, NotificationsObserver);
#[uniffi::export(async_runtime = "tokio")]
impl NotificationsViewModel {
    pub async fn load(&self, project_id: String, session_id: String) {
        self.update(|s| {
            s.loading = true;
            s.error = None;
        });
        let result = fetch_notifications(&self.app, &project_id, &session_id).await;
        self.update(|s| {
            s.loading = false;
            match result {
                Ok(items) => s.items = items,
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
    }
    pub async fn dismiss(&self, id: String) {
        let result: crate::error::Result<serde_json::Value> =
            self.app.post(&format!("/api/notifications/{}/dismiss", seg(&id)), &serde_json::json!({})).await;
        self.update(|s| match result {
            Ok(_) => s.items.retain(|n| n.id != id),
            Err(e) => s.error = Some(UserError::from(&e)),
        });
    }
}
pub(crate) async fn fetch_notifications(app: &crate::App, project: &str, session: &str) -> crate::error::Result<Vec<Notification>> {
    let mut items = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let mut url = String::from("/api/notifications?limit=100&filter=all");
        if !project.is_empty() {
            url.push_str(&format!("&projectId={}", seg(project)));
        }
        if !session.is_empty() {
            url.push_str(&format!("&sessionId={}", seg(session)));
        }
        if let Some(c) = &cursor {
            url.push_str(&format!("&cursor={}", seg(c)));
        }
        let page: Page = app.get(&url).await?;
        for value in page.notifications {
            let mut item =
                serde_json::from_value::<Notification>(value.clone()).map_err(|e| crate::error::CoreError::Unexpected(e.to_string()))?;
            let key = match item.kind.as_str() {
                "secret_request" => "secretRequestId",
                "operations_approval" => "approvalId",
                _ => "attentionMarkerId",
            };
            item.request_id =
                value.get("metadata").and_then(|m| m.get(key)).and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(str::to_owned);
            items.push(item);
        }
        if page.next_cursor.is_none() || page.next_cursor == cursor {
            break;
        }
        cursor = page.next_cursor;
    }
    Ok(items)
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct RequestState {
    pub title: String,
    pub reason: String,
    pub options: Vec<String>,
    pub status: String,
    pub answer: Option<String>,
    pub irreversible: bool,
    pub delivery_unconfirmed: bool,
    pub can_respond: bool,
    pub existing_version: Option<String>,
    pub busy: bool,
    pub error: Option<UserError>,
}
observable!(RequestViewModel, RequestState, RequestObserver);
#[uniffi::export(async_runtime = "tokio")]
impl RequestViewModel {
    pub async fn load(&self, project_id: String, session_id: String, request_id: String, secret: bool, approval: bool) {
        let mut started = false;
        self.update(|s| {
            if !s.busy {
                s.busy = true;
                s.error = None;
                started = true;
            }
        });
        if !started {
            return;
        }
        let result: crate::error::Result<serde_json::Value> =
            self.app.get(&request_path(&project_id, &session_id, &request_id, secret, approval)).await;
        self.update(|s| {
            s.busy = false;
            match result {
                Err(e) => {
                    s.can_respond = false;
                    s.error = Some(UserError::from(&e));
                }
                Ok(v) => {
                    let r = &v[if approval { "approval" } else { "request" }];
                    s.irreversible = matches!(r["action"].as_str(), Some("delete_workspace" | "delete_node"));
                    s.answer = r["resolvedAnswer"].as_str().map(str::to_owned);
                    s.title = if approval {
                        format!(
                            "{} · {} {}",
                            r["action"].as_str().unwrap_or_default(),
                            r["targetType"].as_str().unwrap_or_default(),
                            r["targetId"].as_str().unwrap_or_default()
                        )
                    } else {
                        r["envKey"].as_str().unwrap_or_default().to_owned()
                    };
                    s.reason = r["reason"].as_str().unwrap_or_default().to_owned();
                    s.options = r["options"]
                        .as_array()
                        .map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_owned)).collect())
                        .unwrap_or_default();
                    s.can_respond = v["canResolve"].as_bool().unwrap_or_else(|| r["canAnswer"].as_bool().unwrap_or(false));
                    s.existing_version = v["existing"]["version"].as_str().map(str::to_owned);
                    if approval {
                        s.can_respond = r["status"] == "pending" && r["requestingProjectId"].as_str() == Some(project_id.as_str());
                        s.options = vec!["approve".into(), "deny".into()];
                        if let Some(evidence) = r["evidenceSummary"].as_str() {
                            s.reason.push('\n');
                            s.reason.push_str(evidence);
                        }
                        if let Some(facts) = r["targetSummary"].as_object() {
                            for (key, value) in facts {
                                if !value.is_null() {
                                    s.reason.push_str(&format!(
                                        "\n{key}: {}",
                                        value.as_str().map(str::to_owned).unwrap_or_else(|| value.to_string())
                                    ));
                                }
                            }
                        }
                    }
                    s.status = if secret || approval {
                        r["status"].as_str().unwrap_or_default().to_owned()
                    } else if r["resolvedAt"].as_i64().is_some() {
                        "answered".into()
                    } else if r["expired"].as_bool() == Some(true) {
                        "expired".into()
                    } else if !r["resolvedAnswer"].is_null() {
                        "delivering".into()
                    } else {
                        String::new()
                    };
                }
            }
        });
    }
    /// Secret values are transient arguments, never retained in observable state or chat.
    // UniFFI exports this flat intent to both shells. No secret-bearing form is retained.
    #[allow(clippy::too_many_arguments)]
    pub async fn respond(
        &self,
        project_id: String,
        session_id: String,
        request_id: String,
        secret: bool,
        approval: bool,
        value: String,
        decline: bool,
        expected_version: Option<String>,
    ) -> bool {
        let mut started = false;
        self.update(|s| {
            if !s.busy && s.can_respond && (decline || if secret { !value.is_empty() } else { !value.trim().is_empty() }) {
                s.busy = true;
                started = true;
            }
        });
        if !started {
            return false;
        }
        let body = if approval {
            serde_json::json!({"decision":value})
        } else if secret {
            if decline {
                serde_json::json!({})
            } else {
                match expected_version {
                    Some(version) => serde_json::json!({"value":value,"replaceExisting":true,"expectedExistingVersion":version}),
                    None => serde_json::json!({"value":value}),
                }
            }
        } else {
            serde_json::json!({"answer":value})
        };
        let path = format!(
            "{}/{}",
            request_path(&project_id, &session_id, &request_id, secret, approval),
            if approval {
                "decision"
            } else if secret {
                if decline {
                    "decline"
                } else {
                    "fulfill"
                }
            } else {
                "resolve"
            }
        );
        let result: crate::error::Result<serde_json::Value> = self.app.post(&path, &body).await;
        let ok = result.is_ok();
        self.update(|s| {
            s.busy = false;
            match result {
                Ok(v) => {
                    s.delivery_unconfirmed = v["delivered"].as_bool() == Some(false) || v["agentNotified"].as_bool() == Some(false);
                    s.can_respond = false;
                    s.status = if secret {
                        v["request"]["status"].as_str().unwrap_or(if decline { "declined" } else { "fulfilled" })
                    } else if approval {
                        v["approval"]["status"].as_str().unwrap_or("pending")
                    } else if v["resolved"].as_bool() == Some(true) {
                        "answered"
                    } else {
                        "delivering"
                    }
                    .into();
                    s.answer = if secret || approval { None } else { v["answer"].as_str().map(str::to_owned) };
                    s.error = None;
                }
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
        ok
    }
}
fn request_path(project: &str, session: &str, id: &str, secret: bool, approval: bool) -> String {
    if approval {
        format!("/api/admin/operations/approvals/{}", seg(id))
    } else if secret {
        format!("/api/projects/{}/secret-requests/{}", seg(project), seg(id))
    } else {
        format!("/api/projects/{}/sessions/{}/attention/{}", seg(project), seg(session), seg(id))
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RequestRef {
    pub id: String,
    pub session_id: Option<String>,
    pub secret: bool,
    pub approval: bool,
}
pub(crate) fn collect_refs(value: &serde_json::Value, refs: &mut Vec<RequestRef>, depth: usize) {
    if depth > 12 {
        return;
    }
    match value {
        serde_json::Value::Object(map) => {
            for (key, value) in map {
                if matches!(key.as_str(), "humanInputRequest" | "secretRequest" | "approval") {
                    if let Some(id) = value["id"].as_str().filter(|s| !s.is_empty()) {
                        let r = RequestRef {
                            id: id.into(),
                            session_id: value["sessionId"].as_str().map(str::to_owned),
                            secret: key == "secretRequest",
                            approval: key == "approval",
                        };
                        if !refs.contains(&r) {
                            refs.push(r);
                        }
                    }
                } else {
                    collect_refs(value, refs, depth + 1);
                }
            }
        }
        serde_json::Value::Array(a) => {
            for v in a {
                collect_refs(v, refs, depth + 1);
            }
        }
        serde_json::Value::String(s) => {
            let parsed = serde_json::from_str::<serde_json::Value>(s).ok().or_else(|| {
                let start = s.find('{')?;
                let end = s.rfind('}')?;
                serde_json::from_str(s.get(start..=end)?).ok()
            });
            if let Some(v) = parsed {
                collect_refs(&v, refs, depth + 1);
            }
        }
        _ => {}
    }
}
#[uniffi::export]
pub fn notification_url(server_url: String, action_url: String) -> Option<String> {
    let mut base = reqwest::Url::parse(&server_url).ok()?;
    if let Some(host) = base.host_str().and_then(|h| h.strip_prefix("api.")).map(|h| format!("app.{h}")) {
        base.set_host(Some(&host)).ok()?;
    }
    let url = base.join(&action_url).ok()?;
    matches!(url.scheme(), "http" | "https").then(|| url.to_string())
}
