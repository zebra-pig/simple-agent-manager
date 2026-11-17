//! Automation for one chat: what it waits for (event subscriptions) and what is
//! set to message it (schedules and standing watches), read through the same
//! project endpoints as web's Automation drawer. Words stay in the shells; the
//! core classifies filters and row states so both shells agree.
use crate::{error::UserError, members, session::seg};
use serde::Serialize;
use serde_json::Value;

const PAGE_LIMIT: u32 = 200;
/// Web reads at most this many schedule/watch pages, then marks the list partial.
const MAX_PAGES: usize = 2;
const ATTENTION_WINDOW_MS: i64 = 3 * 24 * 60 * 60 * 1000;
const SAM_RELAY_PREFIX: &str = "agent-dm.";
const WATCH_TARGET_NOT_OWNED: &str = "Standing watch creator does not own the target chat";
const RUNNER_PAUSES: [&str; 2] = [WATCH_TARGET_NOT_OWNED, "Creator project access was revoked"];

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct AutomationState {
    pub project_id: String,
    pub session_id: String,
    pub loaded: bool,
    /// Owner, admin or maintainer: may stop waits and add reminders.
    pub can_write: bool,
    /// Active waits a person can see by default (SAM relays left out).
    pub waits: Vec<ChatWait>,
    /// SAM's own agent-to-agent relays, shown only on request.
    pub relays: Vec<ChatWait>,
    pub upcoming: Vec<UpcomingAutomation>,
    /// More schedules/watches exist than were read.
    pub upcoming_truncated: bool,
    pub loading: bool,
    /// A wait being stopped, or a reminder being saved.
    pub busy: bool,
    pub waits_error: Option<UserError>,
    pub upcoming_error: Option<UserError>,
    pub error: Option<UserError>,
}

/// What a filter waits for, for the shell to put into words.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum WaitEvent {
    /// A post on these agent channels (empty: any channel).
    Channel { names: Vec<String> },
    /// One event type, or several that read the same (CI checks).
    Known { event_type: String },
    /// Every CI completion type at once: "CI to finish".
    Ci,
    /// An event type the shells have no words for; `source` names its family.
    Named { source: Option<String>, event_type: String },
    /// No single type: GitHub activity, SAM activity, or any event.
    Family { source: Option<String> },
}

/// What the filter is pinned to: "on PR #12", "on commit abc1234".
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct WaitSubject {
    pub kind: String,
    pub id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WaitOwner {
    Human,
    Agent,
    /// SAM, a policy or a standing watch: managed elsewhere, not stoppable here.
    Managed,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ChatWait {
    pub id: String,
    pub event: WaitEvent,
    pub subject: Option<WaitSubject>,
    /// The chat that receives matches; `None` or this chat reads "This chat".
    pub target_session_id: Option<String>,
    pub owner: WaitOwner,
    pub owner_name: Option<String>,
    pub created_at: i64,
    pub expires_at: Option<i64>,
    pub last_matched_at: Option<i64>,
    pub reason: Option<String>,
    /// The viewer may stop it from here.
    pub can_stop: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum UpcomingKind {
    Schedule,
    Watch,
}

/// Web's row state, collapsed for display.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum UpcomingStatus {
    Scheduled,
    /// Due in the past but not started yet.
    Late,
    Starting,
    Done,
    Cancelled,
    Ended,
    On,
    Paused,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct UpcomingAutomation {
    pub id: String,
    pub kind: UpcomingKind,
    /// The reason, else the prompt's first line (80 chars). `None`: the shell
    /// says "Message a chat"/"Start a chat", or "When …" for a watch.
    pub title: Option<String>,
    pub status: UpcomingStatus,
    pub needs_attention: bool,
    /// Schedules: when it runs.
    pub due_at: Option<i64>,
    /// Watches: what triggers it.
    pub event: Option<WaitEvent>,
    pub subject: Option<WaitSubject>,
    /// Messages this chat (otherwise it starts a new one).
    pub messages_this_chat: bool,
    pub executions: u32,
    pub max_executions: Option<u32>,
}

observable!(AutomationViewModel, AutomationState, AutomationObserver);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CreateSchedule<'a> {
    action: ScheduleAction<'a>,
    due_at: i64,
    display_timezone: &'a str,
    idempotency_key: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<&'a str>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ScheduleAction<'a> {
    kind: &'static str,
    session_id: &'a str,
    prompt: &'a str,
}

#[uniffi::export(async_runtime = "tokio")]
impl AutomationViewModel {
    pub async fn load(&self, project_id: String, session_id: String) {
        self.update(|s| {
            if s.project_id != project_id || s.session_id != session_id {
                *s = AutomationState { project_id: project_id.clone(), session_id: session_id.clone(), ..Default::default() };
            }
            s.loading = true;
            s.error = None;
        });
        let project = format!("/api/projects/{}", seg(&project_id));
        let session = seg(&session_id);
        let viewer = self.app.state().viewer.map(|v| v.id).unwrap_or_default();
        let waits_path = format!("{project}/event-subscriptions?limit={PAGE_LIMIT}&sessionId={session}&state=active");
        let schedules_path = format!("{project}/schedules?limit={PAGE_LIMIT}&sessionId={session}");
        let watches_path = format!("{project}/standing-watches?limit={PAGE_LIMIT}&sessionId={session}");
        let (waits, schedules, watches, members) = tokio::join!(
            self.app.get::<Value>(&waits_path),
            self.pages(&schedules_path, "schedules"),
            self.pages(&watches_path, "watches"),
            members::project_members(&self.app, &project_id),
        );
        let now = now_ms();
        self.update(|s| {
            if s.project_id != project_id || s.session_id != session_id {
                return;
            }
            s.loading = false;
            s.loaded = true;
            // A failed membership read keeps the controls hidden: the server is the authority.
            s.can_write = members.map(|m| members::can_write(&m, &viewer)).unwrap_or(false);
            match waits {
                Ok(body) => {
                    let (relays, waits): (Vec<_>, Vec<_>) = parse_waits(&body, s.can_write).into_iter().partition(|(relay, _)| *relay);
                    s.waits = waits.into_iter().map(|(_, w)| w).collect();
                    s.relays = relays.into_iter().map(|(_, w)| w).collect();
                    s.waits_error = None;
                }
                Err(e) => s.waits_error = Some(UserError::from(&e)),
            }
            match (schedules, watches) {
                (Ok((schedules, more_schedules)), Ok((watches, more_watches))) => {
                    s.upcoming = upcoming(&schedules, &watches, &session_id, now);
                    s.upcoming_truncated = more_schedules || more_watches;
                    s.upcoming_error = None;
                }
                (Err(e), _) | (_, Err(e)) => s.upcoming_error = Some(UserError::from(&e)),
            }
        });
    }

    /// Stops one wait (web's "Stop waiting"), then rereads the lists.
    pub async fn stop_waiting(&self, subscription_id: String, reason: Option<String>) -> bool {
        let Some(state) = self.claim(|s| s.can_write && s.waits.iter().any(|w| w.id == subscription_id && w.can_stop)) else { return false };
        let reason = reason.map(|r| r.trim().to_owned()).filter(|r| !r.is_empty());
        let body = match &reason {
            Some(reason) => serde_json::json!({"reason": reason}),
            None => serde_json::json!({}),
        };
        let result: crate::error::Result<Value> = self
            .app
            .post(&format!("/api/projects/{}/event-subscriptions/{}/cancel", seg(&state.project_id), seg(&subscription_id)), &body)
            .await;
        self.settle(state, result).await
    }

    /// Schedules a message to this chat ("Remind this chat later"). The shell
    /// supplies one idempotency key per draft so a retried save is not doubled.
    pub async fn remind_later(&self, prompt: String, due_at: i64, timezone: String, idempotency_key: String) -> bool {
        let prompt = prompt.trim().to_owned();
        if prompt.is_empty() || due_at <= now_ms() {
            return false;
        }
        let Some(state) = self.claim(|s| s.can_write) else { return false };
        let body = CreateSchedule {
            action: ScheduleAction { kind: "message_session", session_id: &state.session_id, prompt: &prompt },
            due_at,
            display_timezone: &timezone,
            idempotency_key: &idempotency_key,
            reason: None,
        };
        let result: crate::error::Result<Value> =
            self.app.post(&format!("/api/projects/{}/schedules", seg(&state.project_id)), &body).await;
        self.settle(state, result).await
    }
}

impl AutomationViewModel {
    async fn pages(&self, path: &str, key: &str) -> crate::error::Result<(Vec<Value>, bool)> {
        let mut rows = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..MAX_PAGES {
            let url = match &cursor {
                Some(c) => format!("{path}&cursor={}", seg(c)),
                None => path.to_owned(),
            };
            let page: Value = self.app.get(&url).await?;
            rows.extend(page[key].as_array().cloned().unwrap_or_default());
            cursor = page["nextCursor"].as_str().filter(|c| !c.is_empty()).map(str::to_owned);
            if cursor.is_none() {
                return Ok((rows, false));
            }
        }
        Ok((rows, true))
    }

    fn claim(&self, allowed: impl FnOnce(&AutomationState) -> bool) -> Option<AutomationState> {
        let mut claimed = None;
        self.update(|s| {
            if s.busy || s.project_id.is_empty() || !allowed(s) {
                return;
            }
            s.busy = true;
            s.error = None;
            claimed = Some(s.clone());
        });
        claimed
    }

    async fn settle(&self, state: AutomationState, result: crate::error::Result<Value>) -> bool {
        let ok = result.is_ok();
        self.update(|s| {
            if s.project_id == state.project_id && s.session_id == state.session_id {
                s.busy = false;
                if let Err(e) = &result {
                    s.error = Some(UserError::from(e));
                }
            }
        });
        if ok {
            self.load(state.project_id, state.session_id).await;
        }
        ok
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn list(v: &Value) -> Vec<String> {
    match v {
        Value::String(s) => vec![s.clone()],
        Value::Array(items) => items.iter().filter_map(|i| i.as_str().map(str::to_owned)).collect(),
        _ => vec![],
    }
}
fn one(v: &Value) -> Option<String> {
    let mut items = list(v);
    (items.len() == 1).then(|| items.remove(0))
}

const CI_TYPES: [&str; 3] = ["check_run.completed", "check_suite.completed", "workflow_run.completed"];
/// Event types the shells have phrases for (web's `EVENT_PHRASES`).
pub const KNOWN_EVENT_TYPES: [&str; 24] = [
    "issues.opened",
    "issues.labeled",
    "issues.closed",
    "issue_comment.created",
    "pull_request.opened",
    "pull_request.closed",
    "pull_request.synchronize",
    "pull_request.review_requested",
    "pull_request_review.submitted",
    "pull_request_review_comment.created",
    "push",
    "check_run.completed",
    "check_suite.completed",
    "workflow_run.completed",
    "task.started",
    "task.completed",
    "task.failed",
    "task.cancelled",
    "session.failed",
    "session.archived",
    "deployment.release.applied",
    "deployment.release.failed",
    "webhook.accepted",
    "webhook.filtered",
];

/// Same decision order as web's `describeEventFilter`.
pub fn describe_filter(filter: &Value) -> (WaitEvent, Option<WaitSubject>) {
    let source = one(&filter["source"]);
    if source.as_deref() == Some("sam.agent_channel") {
        return (WaitEvent::Channel { names: list(&filter["subjectId"]) }, None);
    }
    let subject = match (one(&filter["subjectType"]), one(&filter["subjectId"])) {
        (Some(kind), Some(id)) => Some(WaitSubject { kind, id }),
        _ => None,
    };
    let types = list(&filter["eventType"]);
    let known = |t: &str| KNOWN_EVENT_TYPES.contains(&t);
    let event = if types.len() == 1 && known(&types[0]) {
        WaitEvent::Known { event_type: types[0].clone() }
    } else if types.len() > 1 && types.iter().all(|t| CI_TYPES.contains(&t.as_str())) {
        WaitEvent::Ci
    } else if types.len() == 1 {
        WaitEvent::Named { source, event_type: types[0].clone() }
    } else {
        WaitEvent::Family { source }
    };
    (event, subject)
}

/// `(is_sam_relay, wait)` for each subscription.
fn parse_waits(body: &Value, can_write: bool) -> Vec<(bool, ChatWait)> {
    body["subscriptions"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|sub| {
            let id = sub["id"].as_str()?.to_owned();
            let filter = &sub["filter"];
            let relay = list(&filter["subjectType"]).iter().any(|t| t == "agent_channel")
                && list(&filter["subjectId"]).iter().any(|i| i.starts_with(SAM_RELAY_PREFIX));
            let owner = match sub["owner"]["type"].as_str() {
                Some("human") => WaitOwner::Human,
                Some("agent") => WaitOwner::Agent,
                _ => WaitOwner::Managed,
            };
            let (event, subject) = describe_filter(filter);
            let active = sub["state"].as_str() == Some("active");
            Some((
                relay,
                ChatWait {
                    id,
                    event,
                    subject,
                    target_session_id: sub["deliveryPreference"]["target"]["sessionId"].as_str().map(str::to_owned),
                    owner,
                    owner_name: sub["owner"]["name"].as_str().map(str::to_owned),
                    created_at: sub["createdAt"].as_i64().unwrap_or(0),
                    expires_at: sub["expiresAt"].as_i64(),
                    last_matched_at: sub["lastMatchedAt"].as_i64(),
                    reason: sub["reason"].as_str().map(str::trim).filter(|r| !r.is_empty()).map(str::to_owned),
                    can_stop: can_write && active && !relay && owner != WaitOwner::Managed,
                },
            ))
        })
        .collect()
}

fn title(reason: &Value, prompt: &Value) -> Option<String> {
    if let Some(reason) = reason.as_str().map(str::trim).filter(|r| !r.is_empty()) {
        return Some(reason.to_owned());
    }
    let line = prompt.as_str()?.lines().map(str::trim).find(|l| !l.is_empty())?;
    Some(if line.chars().count() > 80 { format!("{}…", line.chars().take(79).collect::<String>()) } else { line.to_owned() })
}

/// Web's `fromSchedule`/`fromWatch` and its "Coming up" ordering.
pub(crate) fn upcoming(schedules: &[Value], watches: &[Value], session_id: &str, now: i64) -> Vec<UpcomingAutomation> {
    let mut rows: Vec<UpcomingAutomation> = schedules
        .iter()
        .filter(|s| s["watchId"].as_str().is_none())
        .filter_map(|s| {
            let id = s["id"].as_str()?.to_owned();
            let due_at = s["dueAt"].as_i64();
            let state = s["state"].as_str().unwrap_or_default();
            let status = match state {
                "pending" if due_at.is_some_and(|d| d < now) => UpcomingStatus::Late,
                "pending" => UpcomingStatus::Scheduled,
                "processing" => UpcomingStatus::Starting,
                "admitted" | "failed" | "ambiguous" => UpcomingStatus::Done,
                "cancelled" => UpcomingStatus::Cancelled,
                _ => UpcomingStatus::Ended,
            };
            let needs_attention = matches!(state, "ambiguous" | "failed" | "expired")
                && s["updatedAt"].as_i64().is_some_and(|u| now - u <= ATTENTION_WINDOW_MS);
            let finished = matches!(status, UpcomingStatus::Done | UpcomingStatus::Cancelled | UpcomingStatus::Ended);
            if finished && !needs_attention {
                return None;
            }
            let action = &s["action"];
            Some(UpcomingAutomation {
                id,
                kind: UpcomingKind::Schedule,
                title: title(&s["reason"], &action["prompt"]),
                status,
                needs_attention,
                due_at,
                event: None,
                subject: None,
                messages_this_chat: action["kind"] == "message_session" && action["sessionId"].as_str() == Some(session_id),
                executions: 0,
                max_executions: None,
            })
        })
        .collect();
    rows.sort_by_key(|r| r.due_at.unwrap_or(i64::MAX));
    rows.extend(watches.iter().filter(|w| w["state"].as_str() != Some("revoked")).filter_map(|w| {
        let (event, subject) = describe_filter(&w["filter"]);
        let executions = w["executionCount"].as_u64().unwrap_or(0) as u32;
        let max_executions = w["maxExecutions"].as_u64().map(|m| m as u32);
        let paused = w["state"].as_str() == Some("paused");
        let runner_paused = paused && w["lastError"].as_str().is_some_and(|e| RUNNER_PAUSES.contains(&e));
        let action = &w["action"];
        Some(UpcomingAutomation {
            id: w["id"].as_str()?.to_owned(),
            kind: UpcomingKind::Watch,
            title: w["reason"].as_str().map(str::trim).filter(|r| !r.is_empty()).map(str::to_owned),
            status: if paused { UpcomingStatus::Paused } else { UpcomingStatus::On },
            needs_attention: runner_paused || max_executions.is_some_and(|m| executions >= m),
            due_at: None,
            event: Some(event),
            subject,
            messages_this_chat: action["kind"] == "message_session" && action["sessionId"].as_str() == Some(session_id),
            executions,
            max_executions,
        })
    }));
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn filters_follow_web_decision_order() {
        assert_eq!(describe_filter(&json!({"source": "sam.agent_channel", "subjectId": ["ops"]})).0, WaitEvent::Channel { names: vec!["ops".into()] });
        let (event, subject) = describe_filter(&json!({"source": "github", "eventType": ["check_run.completed", "workflow_run.completed"], "subjectType": "commit", "subjectId": "abc"}));
        assert_eq!(event, WaitEvent::Ci);
        assert_eq!(subject, Some(WaitSubject { kind: "commit".into(), id: "abc".into() }));
        assert_eq!(describe_filter(&json!({"eventType": "push"})).0, WaitEvent::Known { event_type: "push".into() });
        assert_eq!(
            describe_filter(&json!({"source": "github", "eventType": "release.published"})).0,
            WaitEvent::Named { source: Some("github".into()), event_type: "release.published".into() }
        );
        assert_eq!(describe_filter(&json!({"source": ["a", "b"]})).0, WaitEvent::Family { source: None });
    }

    #[test]
    fn relays_and_managed_waits_cannot_be_stopped() {
        let waits = parse_waits(
            &json!({"subscriptions": [
                {"id": "mine", "state": "active", "owner": {"type": "agent"}, "filter": {"eventType": "push"}},
                {"id": "relay", "state": "active", "owner": {"type": "agent"}, "filter": {"subjectType": "agent_channel", "subjectId": "agent-dm.x"}},
                {"id": "watch", "state": "active", "owner": {"type": "standing_watch"}, "filter": {}}
            ]}),
            true,
        );
        assert!(waits[0].1.can_stop && !waits[0].0);
        assert!(waits[1].0 && !waits[1].1.can_stop);
        assert!(!waits[2].1.can_stop);
        assert!(!parse_waits(&json!({"subscriptions": [{"id": "x", "state": "active", "owner": {"type": "human"}, "filter": {}}]}), false)[0].1.can_stop);
    }

    #[test]
    fn upcoming_drops_quiet_finished_rows_and_orders_by_due_time() {
        let now = 10 * ATTENTION_WINDOW_MS;
        let rows = upcoming(
            &[
                json!({"id": "later", "state": "pending", "dueAt": now + 2000, "action": {"kind": "message_session", "sessionId": "s", "prompt": "\n  Check the deploy\nmore"}}),
                json!({"id": "late", "state": "pending", "dueAt": now - 1, "reason": "Nudge", "action": {"kind": "start_session", "prompt": "x"}}),
                json!({"id": "done", "state": "admitted", "dueAt": 1, "action": {}}),
                json!({"id": "failed", "state": "failed", "dueAt": now + 1, "updatedAt": now - 1000, "action": {}}),
                json!({"id": "old-failure", "state": "failed", "updatedAt": 0, "action": {}}),
                json!({"id": "from-watch", "state": "pending", "watchId": "w", "action": {}}),
            ],
            &[
                json!({"id": "w", "state": "active", "filter": {"eventType": "push"}, "executionCount": 3, "maxExecutions": 3, "action": {"kind": "message_session", "sessionId": "s"}}),
                json!({"id": "gone", "state": "revoked", "filter": {}}),
            ],
            "s",
            now,
        );
        let ids: Vec<_> = rows.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, ["late", "failed", "later", "w"]);
        assert_eq!(rows[0].status, UpcomingStatus::Late);
        assert_eq!(rows[0].title.as_deref(), Some("Nudge"));
        assert!(rows[1].needs_attention);
        assert_eq!(rows[2].title.as_deref(), Some("Check the deploy"));
        assert!(rows[2].messages_this_chat);
        assert!(rows[3].needs_attention, "a watch that used all its runs needs attention");
    }
}
