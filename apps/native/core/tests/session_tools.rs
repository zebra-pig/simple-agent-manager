//! The chat tools that used to hand off to web — Related, Automation, Comments,
//! Share, Report, Retry and Fork — against a local server speaking web's
//! contracts. Each mutation asserts its exact request body.
mod common;
use common::{serve, MemoryStore, Request};
use sam_core::*;
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

fn body(r: &Request) -> Value {
    serde_json::from_slice(&r.body).unwrap()
}

async fn signed_in(route: common::Route) -> Arc<App> {
    let server = serve(route).await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let app = App::new(Box::new(store), None);
    app.refresh_viewer().await;
    app
}

fn members() -> Value {
    json!({"members": [
        {"userId": "me", "role": "maintainer", "status": "active", "user": {"name": "Me"}},
        {"userId": "owner", "role": "owner", "status": "active", "user": {"name": "Olivia"}},
        {"userId": "bo", "role": "admin", "status": "active", "user": {"name": "Bo", "email": "bo@x"}},
        {"userId": "vic", "role": "viewer", "status": "active", "user": {"name": "Vic"}},
        {"userId": "gone", "role": "admin", "status": "removed", "user": {"name": "Gone"}}
    ]})
}

fn session(access: &str) -> ChatSession {
    ChatSession {
        workspace_id: None,
        agent_session_id: None,
        viewer_access: Some(access.into()),
        is_mine: false,
        id: "s".into(),
        topic: Some("**Fix** login".into()),
        status: SessionStatus::Active,
        message_count: 0,
        started_at: 0,
        last_message_at: None,
        task_id: Some("t".into()),
        is_idle: false,
        task: Some(TaskSummary {
            id: "t".into(),
            status: "failed".into(),
            execution_step: None,
            terminal_reason: None,
            error_message: Some("boom".into()),
            output_branch: Some("sam/fix".into()),
            output_pr_url: None,
            output_summary: None,
        }),
    }
}

#[tokio::test]
async fn related_work_reads_the_session_links() {
    let app = signed_in(Arc::new(|r| match r.path.as_str() {
        "/api/auth/get-session" => (200, json!({"user": {"id": "me"}}).to_string()),
        "/api/projects/p/sessions/s/links" => (
            200,
            json!({"ideas": {"items": [{"ideaId": "i", "title": "Idea", "status": "ready", "relations": ["works_on"]}], "total": 1},
                   "files": {"items": [], "total": 0},
                   "pullRequests": {"items": [{"url": "https://gh/pr/7", "number": 7, "state": {"state": "merged", "isDraft": false, "title": "Ship", "checksState": "success", "stale": false}}], "total": 1}})
            .to_string(),
        ),
        _ => (404, "{}".into()),
    }))
    .await;
    let related = LinkedWorkViewModel::new(app);
    related.load("p".into(), "s".into()).await;
    let work = related.state().work.unwrap();
    assert_eq!(work.ideas[0].relations, vec![LinkRelation::WorksOn]);
    assert_eq!(work.pull_requests[0].status, Some(PullRequestStatus::Merged));
    assert_eq!(work.pull_requests[0].checks, Some(ChecksStatus::Passed));
    assert!(related.state().error.is_none());
}

#[tokio::test]
async fn automation_lists_waits_and_stops_and_schedules_with_web_bodies() {
    let posts: Arc<Mutex<Vec<(String, Value)>>> = Arc::default();
    let seen = posts.clone();
    let app = signed_in(Arc::new(move |r| {
        if r.method == "POST" {
            seen.lock().unwrap().push((r.path.clone(), body(r)));
            return (200, json!({}).to_string());
        }
        let b = match r.path.as_str() {
            "/api/auth/get-session" => json!({"user": {"id": "me"}}),
            "/api/projects/p/members" => members(),
            "/api/projects/p/event-subscriptions?limit=200&sessionId=s&state=active" => json!({"subscriptions": [
                {"id": "ci", "state": "active", "owner": {"type": "agent"}, "createdAt": 1, "filter": {"source": "github", "eventType": ["check_run.completed", "check_suite.completed"], "subjectType": "pull_request", "subjectId": "12"}, "deliveryPreference": {"target": {"sessionId": "s"}}},
                {"id": "relay", "state": "active", "owner": {"type": "agent"}, "createdAt": 1, "filter": {"subjectType": "agent_channel", "subjectId": "agent-dm.a.b"}}
            ], "hasMore": false}),
            "/api/projects/p/schedules?limit=200&sessionId=s" => json!({"schedules": [], "nextCursor": "c1"}),
            "/api/projects/p/schedules?limit=200&sessionId=s&cursor=c1" => json!({"schedules": [{"id": "r", "state": "pending", "dueAt": 9_999_999_999_999i64, "action": {"kind": "message_session", "sessionId": "s", "prompt": "Check CI"}}], "nextCursor": null}),
            "/api/projects/p/standing-watches?limit=200&sessionId=s" => json!({"watches": [], "nextCursor": null}),
            _ => return (404, "{}".into()),
        };
        (200, b.to_string())
    }))
    .await;
    let automation = AutomationViewModel::new(app);
    automation.load("p".into(), "s".into()).await;
    let state = automation.state();
    assert!(state.can_write);
    assert_eq!(state.waits.len(), 1);
    assert_eq!(state.waits[0].event, WaitEvent::Ci);
    assert_eq!(state.relays.len(), 1);
    assert_eq!(state.upcoming[0].title.as_deref(), Some("Check CI"), "second schedule page is read");
    assert!(automation.stop_waiting("ci".into(), Some("  done ".into())).await);
    assert!(!automation.stop_waiting("relay".into(), None).await, "relays are never stopped here");
    assert!(automation.remind_later("Look again".into(), 9_999_999_999_000, "Europe/Zurich".into(), "key-1".into()).await);
    assert!(!automation.remind_later("Past".into(), 1, "UTC".into(), "key-2".into()).await);
    let posts = posts.lock().unwrap();
    assert_eq!(posts[0], ("/api/projects/p/event-subscriptions/ci/cancel".into(), json!({"reason": "done"})));
    assert_eq!(
        posts[1],
        (
            "/api/projects/p/schedules".into(),
            json!({"action": {"kind": "message_session", "sessionId": "s", "prompt": "Look again"}, "dueAt": 9_999_999_999_000i64, "displayTimezone": "Europe/Zurich", "idempotencyKey": "key-1"})
        )
    );
    assert_eq!(posts.len(), 2);
}

#[tokio::test]
async fn comments_create_reply_send_and_resolve_follow_web_composition() {
    let posts: Arc<Mutex<Vec<(String, Value)>>> = Arc::default();
    let seen = posts.clone();
    let app = signed_in(Arc::new(move |r| {
        if r.method == "POST" {
            seen.lock().unwrap().push((r.path.clone(), body(r)));
            return (201, json!({"thread": {"id": "new"}}).to_string());
        }
        let b = match r.path.as_str() {
            "/api/auth/get-session" => json!({"user": {"id": "me"}}),
            "/api/projects/p/members" => members(),
            "/api/projects/p/sessions/s/comments?anchorKind=message&limit=500" => json!({"threads": [
                {"id": "t1", "anchor": {"kind": "message", "messageId": "m1", "quote": "the line"}, "author": {"kind": "human", "id": "bo", "name": "Bo"}, "body": "Why?", "status": "open", "createdAt": 10, "replies": []},
                {"id": "t2", "anchor": {"kind": "message", "messageId": "m2", "quote": null}, "author": {"kind": "human", "id": "me", "name": "Me"}, "body": "Done", "status": "resolved", "createdAt": 20, "replies": [{"id": "r", "author": {"kind": "agent", "id": "a", "displayName": "Agent"}, "body": "ok", "createdAt": 30, "sentToAgent": false}]}
            ], "hasMore": false}),
            _ => return (404, "{}".into()),
        };
        (200, b.to_string())
    }))
    .await;
    let comments = CommentsViewModel::new(app);
    comments.load("p".into(), session("reader")).await;
    let state = comments.state();
    assert!(state.can_comment && !state.can_send_to_agent);
    assert_eq!(state.threads[0].id, "t2", "newest activity first");
    assert_eq!(state.counts, CommentCounts { all: 2, needs_you: 1, with_agent: 0, open: 0, resolved: 1 });
    assert!(!comments.create("m1".into(), None, "Note".into(), true, "c0".into()).await, "a reader cannot send to the agent");
    comments.load("p".into(), session("owner")).await;
    assert!(comments.create("m1".into(), Some(" quoted ".into()), " Fix this ".into(), true, "c1".into()).await);
    assert!(comments.reply("t1".into(), "Because".into(), false, "c2".into()).await);
    assert!(comments.resolve("t1".into()).await);
    assert!(comments.reopen("t2".into()).await);
    let posts = posts.lock().unwrap();
    let expected = [
        (
            "/api/projects/p/sessions/s/comments",
            json!({"messageId": "m1", "body": "Fix this", "quote": "quoted", "clientMutationId": "c1"}),
        ),
        ("/api/projects/p/sessions/s/comments/new/send", json!({"body": "Fix this", "clientMutationId": "c1:send"})),
        ("/api/projects/p/sessions/s/comments/t1/replies", json!({"body": "Because", "clientMutationId": "c2"})),
        ("/api/projects/p/sessions/s/comments/t1/resolve", json!({})),
        ("/api/projects/p/sessions/s/comments/t2/reopen", json!({})),
    ];
    assert_eq!(posts.len(), expected.len());
    for (actual, (path, body)) in posts.iter().zip(expected) {
        assert_eq!((actual.0.as_str(), &actual.1), (path, &body));
    }
}

#[tokio::test]
async fn share_grants_renews_and_revokes_with_consent() {
    let calls: Arc<Mutex<Vec<(String, String, Value)>>> = Arc::default();
    let seen = calls.clone();
    let access = |grants: Value| json!({"sessionId": "s", "viewerAccess": "owner", "owner": {"id": "me", "name": "Me"}, "grants": grants, "serverTime": 0});
    let app = signed_in(Arc::new(move |r| {
        let grant = json!({"id": "g", "grantee": {"id": "bo", "name": "Bo"}, "grantedBy": {"id": "me"}, "createdAt": 1, "expiresAt": 600_000, "durationMinutes": 10});
        match (r.method.as_str(), r.path.as_str()) {
            ("GET", "/api/auth/get-session") => (200, json!({"user": {"id": "me"}}).to_string()),
            ("GET", "/api/projects/p/members") => (200, members().to_string()),
            ("GET", "/api/projects/p/sessions/s/access") => (200, access(json!([])).to_string()),
            ("POST", "/api/projects/p/sessions/s/access/grants") => {
                seen.lock().unwrap().push((r.method.clone(), r.path.clone(), body(r)));
                (201, json!({"grant": grant, "created": true, "renewed": false, "access": access(json!([grant]))}).to_string())
            }
            ("DELETE", "/api/projects/p/sessions/s/access/grants/bo") => {
                seen.lock().unwrap().push((r.method.clone(), r.path.clone(), Value::Null));
                (200, json!({"revokedGrantIds": ["g", "child"], "cancelledDeliveryIds": ["d"], "access": access(json!([]))}).to_string())
            }
            _ => (404, "{}".into()),
        }
    }))
    .await;
    let share = SessionAccessViewModel::new(app);
    share.load("p".into(), "s".into(), true).await;
    let state = share.state();
    assert!(state.can_manage && state.can_renew && state.can_add);
    assert_eq!(
        state.candidates.iter().map(|c| c.user_id.as_str()).collect::<Vec<_>>(),
        ["bo", "owner"],
        "the viewer, project viewers and removed members are not offered"
    );
    assert!(!share.grant("bo".into(), 10, false).await, "no request without consent");
    assert!(!share.grant("bo".into(), 15, true).await, "only server durations");
    assert!(share.grant("bo".into(), 10, true).await);
    assert_eq!(share.state().outcome, Some(ShareOutcome::Granted { name: "Bo".into(), until: 600_000 }));
    assert_eq!(share.state().candidates.len(), 1, "a new grantee leaves the picker");
    assert!(share.revoke("bo".into()).await);
    assert_eq!(share.state().outcome, Some(ShareOutcome::Revoked { name: "Bo".into(), cascaded: 1, cancelled_messages: 1 }));
    let calls = calls.lock().unwrap();
    assert_eq!(calls[0].2, json!({"userId": "bo", "durationMinutes": 10, "acknowledgeSharedCredentials": true}));
    assert_eq!(calls[1].0, "DELETE");
    assert_eq!(calls.len(), 2);
}

#[tokio::test]
async fn report_attaches_refs_only_with_consent() {
    let bodies: Arc<Mutex<Vec<Value>>> = Arc::default();
    let seen = bodies.clone();
    let app = signed_in(Arc::new(move |r| match (r.method.as_str(), r.path.as_str()) {
        ("GET", "/api/auth/get-session") => (200, json!({"user": {"id": "me"}}).to_string()),
        ("POST", "/api/report-issue") => {
            seen.lock().unwrap().push(body(r));
            (201, json!({"ideaId": "idea1", "status": "draft", "refsAttached": true, "attachedRefKeys": ["sessionId"], "message": "Report submitted with 1 technical reference attached."}).to_string())
        }
        _ => (404, "{}".into()),
    }))
    .await;
    let refs = ReportRefs { session_id: Some("s".into()), task_id: Some(" ".into()), node_id: None };
    assert_eq!(report_refs_present(&refs), vec!["sessionId".to_string()]);
    let report = ReportViewModel::new(app);
    assert!(!report.submit(" ".into(), "d".into(), true, refs.clone()).await);
    assert!(report.submit(" Broken ".into(), "It broke".into(), true, refs.clone()).await);
    assert_eq!(report.state().submitted.unwrap().id, "idea1");
    report.reset();
    assert!(report.submit("Again".into(), "No refs".into(), false, refs).await);
    let bodies = bodies.lock().unwrap();
    assert_eq!(bodies[0], json!({"title": "Broken", "description": "It broke", "consentToAttachRefs": true, "refs": {"sessionId": "s"}}));
    assert_eq!(bodies[1], json!({"title": "Again", "description": "No refs", "consentToAttachRefs": false}));
}

#[tokio::test]
async fn retry_and_fork_prefill_and_submit_with_the_parent_task() {
    let submits: Arc<Mutex<Vec<Value>>> = Arc::default();
    let seen = submits.clone();
    let app = signed_in(Arc::new(move |r| {
        let b = match (r.method.as_str(), r.path.as_str()) {
            ("GET", "/api/auth/get-session") => json!({"user": {"id": "me"}}),
            ("GET", "/api/projects/p/tasks/t") => json!({"id": "t", "description": "Original prompt"}),
            ("GET", path) if path.starts_with("/api/projects/p/sessions") => json!({"sessions": [], "total": 0}),
            ("GET", path) if path.starts_with("/api/projects/p/agent-profiles") => json!({"items": []}),
            ("POST", "/api/projects/p/tasks/submit") => {
                seen.lock().unwrap().push(body(r));
                json!({"taskId": "t2", "sessionId": "s2", "branchName": "b", "status": "queued"})
            }
            _ => return (404, "{}".into()),
        };
        (200, b.to_string())
    }))
    .await;
    let project = ProjectViewModel::new(app);
    project.load("p".into()).await;
    let prompt = project.derive(DerivedKind::Retry, session("owner")).await;
    assert_eq!(prompt, "Original prompt");
    let derived = project.state().derived.unwrap();
    assert_eq!(
        (derived.parent_label.as_str(), derived.error_message.as_deref(), derived.prompt_loading),
        ("Fix login", Some("boom"), false)
    );
    assert_eq!(project.submit_task(prompt).await.unwrap().session_id, "s2");
    project.finish_submission("s2".into());
    assert!(project.state().derived.is_none(), "an accepted task ends the derivation");
    let fork = project.derive(DerivedKind::Fork, session("owner")).await;
    assert!(fork.contains("Previous session: \"Fix login\"\nParent project ID: p\nParent session ID: s\nParent task ID: t"));
    project.cancel_derived();
    project.submit_task("Plain".into()).await.unwrap();
    let submits = submits.lock().unwrap();
    assert_eq!(submits[0]["parentTaskId"], "t");
    assert_eq!(submits[0]["message"], "Original prompt");
    assert!(submits[1].get("parentTaskId").is_none(), "a cancelled derivation sends no parent");
}
