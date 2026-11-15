mod common;
use common::{serve, MemoryStore};
use sam_core::{App, ChatViewModel, Credentials, NotificationsViewModel, RequestViewModel};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
fn app(server: String) -> Arc<App> {
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    App::new(Box::new(store), None)
}
#[tokio::test]
async fn inbox_loads_all_pages_and_preserves_read_actionable_requests() {
    let server = serve(Arc::new(|r| {
        assert_eq!(r.header("cookie").as_deref(), Some("session=abc"));
        if r.path == "/api/notifications/n1/dismiss" { assert_eq!(r.method, "POST"); return (200, "{}".into()); }
        assert!(r.path.starts_with("/api/notifications?limit=100&filter=all"));
        assert!(!r.path.contains("projectId="));
        let next = r.path.contains("cursor=");
        (200, json!({"notifications":[{
            "id":if next {"n2"} else {"n1"},"projectId":"p1","sessionId":"s1",
            "title":"Question", "type":if next {"secret_request"} else {"needs_input"},
            "readAt":"2026-11-15T00:00:00Z", "metadata":if next {json!({"secretRequestId":"secret1"})} else {json!({"attentionMarkerId":"a1"})}
        }], "nextCursor":if next {Value::Null} else {json!("next/page")}}).to_string())
    })).await;
    let vm = NotificationsViewModel::new(app(server));
    vm.load("".into(), "".into()).await;
    assert!(vm.state().error.is_none());
    assert_eq!(vm.state().items.len(), 2);
    assert_eq!(vm.state().items[0].request_id.as_deref(), Some("a1"));
    assert_eq!(vm.state().items[1].request_id.as_deref(), Some("secret1"));
    vm.dismiss("n1".into()).await;
    assert_eq!(vm.state().items.len(), 1);
}
#[tokio::test]
async fn answers_use_authoritative_options_and_pending_delivery_disables_resubmission() {
    let posts = Arc::new(Mutex::new(0));
    let count = posts.clone();
    let server = serve(Arc::new(move |r| {
        if r.method == "GET" {
            assert_eq!(r.path, "/api/projects/p1/sessions/s1/attention/a1");
            return (200, json!({"request":{"reason":"Full question", "options":["Yes", "No"], "canAnswer":true, "resolvedAt":null, "resolvedAnswer":null}}).to_string());
        }
        assert_eq!(r.path, "/api/projects/p1/sessions/s1/attention/a1/resolve");
        assert_eq!(serde_json::from_slice::<Value>(&r.body).unwrap(), json!({"answer":"Yes"}));
        *count.lock().unwrap() += 1; (200, json!({"resolved":false,"answer":"Yes"}).to_string())
    })).await;
    let vm = RequestViewModel::new(app(server));
    vm.load("p1".into(), "s1".into(), "a1".into(), false, false).await;
    assert_eq!(vm.state().reason, "Full question");
    assert_eq!(vm.state().options, ["Yes", "No"]);
    assert!(vm.respond("p1".into(), "s1".into(), "a1".into(), false, false, "Yes".into(), false, None).await);
    assert_eq!(vm.state().status, "delivering");
    assert!(!vm.state().can_respond);
    assert!(!vm.respond("p1".into(), "s1".into(), "a1".into(), false, false, "Yes".into(), false, None).await);
    assert_eq!(*posts.lock().unwrap(), 1);
}
#[tokio::test]
async fn secrets_use_dedicated_endpoint_and_versioned_replacement_without_retaining_value() {
    let server = serve(Arc::new(|r| {
        if r.method == "GET" {
            return (
                200,
                json!({"request":{"envKey":"TOKEN","reason":"Deploy","status":"pending"},"existing":{"version":"v1"},"canResolve":true})
                    .to_string(),
            );
        }
        assert_eq!(r.path, "/api/projects/p1/secret-requests/r1/fulfill");
        assert_eq!(
            serde_json::from_slice::<Value>(&r.body).unwrap(),
            json!({"value":"private-token", "replaceExisting":true, "expectedExistingVersion":"v1"})
        );
        (200, json!({"request":{"status":"fulfilled"},"agentNotified":true}).to_string())
    }))
    .await;
    let vm = RequestViewModel::new(app(server));
    vm.load("p1".into(), "s1".into(), "r1".into(), true, false).await;
    assert_eq!(vm.state().existing_version.as_deref(), Some("v1"));
    assert!(vm.respond("p1".into(), "s1".into(), "r1".into(), true, false, "private-token".into(), false, Some("v1".into())).await);
    assert_eq!(vm.state().status, "fulfilled");
    assert!(!format!("{:?}", vm.state()).contains("private-token"));
}
#[tokio::test]
async fn chat_extracts_compact_tool_cards_and_finds_requests_outside_message_page() {
    let server = serve(Arc::new(|r| {
        if r.path.starts_with("/api/notifications?") {
            assert!(r.path.contains("projectId=p1&sessionId=s1"));
            return (200,json!({"notifications":[{"id":"n1","projectId":"p1","sessionId":"s1","title":"Old question","type":"needs_input","metadata":{"attentionMarkerId":"older"}}],"nextCursor":null}).to_string());
        }
        (200,json!({"session":{"id":"s1","status":"active"},"messages":[
            {"id":"m1","role":"tool","content":"","toolMetadata":{"rawOutput":[{"type":"text","text":"{\"humanInputRequest\":{\"id\":\"a1\",\"sessionId\":\"s1\"}}"}]}},
            {"id":"m2","role":"tool","content":"{\"secretRequest\":{\"id\":\"secret1\"}}"},
            {"id":"m3","role":"tool","content":"","toolMetadata":{"rawOutput":{"approval":{"id":"approve1"}}}}
        ]}).to_string())
    })).await;
    let vm = ChatViewModel::new(app(server));
    vm.load("p1".into(), "s1".into()).await;
    let state = vm.state();
    assert_eq!(state.messages[0].requests[0].id, "a1");
    assert!(state.messages[1].requests[0].secret);
    assert!(state.messages[2].requests[0].approval);
    assert_eq!(state.notifications[0].request_id.as_deref(), Some("older"));
}
#[tokio::test]
async fn expired_and_forbidden_requests_cannot_be_answered_and_load_failure_can_retry() {
    let fail = Arc::new(Mutex::new(true));
    let failed = fail.clone();
    let server = serve(Arc::new(move |r| {
        assert_eq!(r.method, "GET");
        if *failed.lock().unwrap() {
            (403, json!({"error":"Forbidden"}).to_string())
        } else {
            (
                200,
                json!({"request":{"reason":"Expired","expired":true,"canAnswer":false,"resolvedAnswer":null,"resolvedAt":null}})
                    .to_string(),
            )
        }
    }))
    .await;
    let vm = RequestViewModel::new(app(server));
    vm.load("p1".into(), "s1".into(), "a1".into(), false, false).await;
    assert!(vm.state().error.is_some());
    assert!(!vm.state().can_respond);
    *fail.lock().unwrap() = false;
    vm.load("p1".into(), "s1".into(), "a1".into(), false, false).await;
    assert!(vm.state().error.is_none());
    assert_eq!(vm.state().status, "expired");
    assert!(!vm.respond("p1".into(), "s1".into(), "a1".into(), false, false, "answer".into(), false, None).await);
}
#[tokio::test]
async fn approvals_show_server_target_and_use_decision_endpoint() {
    let server = serve(Arc::new(|r| {
        if r.method == "GET" {
            assert_eq!(r.path, "/api/admin/operations/approvals/op1");
            return (200,json!({"approval":{"action":"delete_node","targetType":"node","targetId":"node1","reason":"Unused","requestingProjectId":"p1","status":"pending"}}).to_string());
        }
        assert_eq!(r.path,"/api/admin/operations/approvals/op1/decision");
        assert_eq!(serde_json::from_slice::<Value>(&r.body).unwrap(),json!({"decision":"deny"}));
        (200,json!({"approval":{"status":"denied"},"delivered":false}).to_string())
    })).await;
    let vm = RequestViewModel::new(app(server));
    vm.load("p1".into(), "s1".into(), "op1".into(), false, true).await;
    assert!(vm.state().irreversible);
    assert!(vm.state().title.contains("node1"));
    assert!(vm.respond("p1".into(), "s1".into(), "op1".into(), false, true, "deny".into(), false, None).await);
    assert_eq!(vm.state().status, "denied");
    assert!(vm.state().delivery_unconfirmed);
    assert!(!vm.state().can_respond);
    vm.load("another-project".into(), "s1".into(), "op1".into(), false, true).await;
    assert!(!vm.state().can_respond);
}
#[tokio::test]
async fn secret_conflicts_keep_form_retryable_and_refresh_rebinds_replacement_version() {
    let conflict = Arc::new(Mutex::new(false));
    let changed = conflict.clone();
    let server = serve(Arc::new(move |r| {
        if r.method == "GET" { return (200,json!({"request":{"envKey":"TOKEN","reason":"Deploy","status":"pending"},"existing":{"version":if *changed.lock().unwrap() {"v2"} else {"v1"}},"canResolve":true}).to_string()); }
        if r.path.ends_with("/decline") { return (200,json!({"request":{"status":"declined"},"agentNotified":true}).to_string()); }
        *changed.lock().unwrap() = true; (409,json!({"error":"Existing value changed"}).to_string())
    })).await;
    let vm = RequestViewModel::new(app(server));
    vm.load("p1".into(), "s1".into(), "r1".into(), true, false).await;
    assert!(!vm.respond("p1".into(), "s1".into(), "r1".into(), true, false, "value".into(), false, Some("v1".into())).await);
    assert!(vm.state().error.is_some());
    assert!(vm.state().can_respond);
    vm.load("p1".into(), "s1".into(), "r1".into(), true, false).await;
    assert_eq!(vm.state().existing_version.as_deref(), Some("v2"));
    assert!(vm.respond("p1".into(), "s1".into(), "r1".into(), true, false, "".into(), true, None).await);
    assert_eq!(vm.state().status, "declined");
    assert!(!vm.state().can_respond);
}
#[test]
fn web_actions_use_signed_in_deployment_and_reject_non_web_schemes() {
    assert_eq!(
        sam_core::notification_url("https://api.example.com".into(), "/projects/p1/chat/s1".into()).as_deref(),
        Some("https://app.example.com/projects/p1/chat/s1")
    );
    assert!(sam_core::notification_url("https://api.example.com".into(), "javascript:alert(1)".into()).is_none());
}
#[tokio::test]
async fn a_new_secret_omits_optional_replacement_fields() {
    let server = serve(Arc::new(|r| {
        if r.method == "GET" {
            return (200, json!({"request":{"envKey":"TOKEN","status":"pending"},"existing":null,"canResolve":true}).to_string());
        }
        assert_eq!(serde_json::from_slice::<Value>(&r.body).unwrap(), json!({"value":"token"}));
        (200, json!({"request":{"status":"fulfilled"},"agentNotified":true}).to_string())
    }))
    .await;
    let vm = RequestViewModel::new(app(server));
    vm.load("p1".into(), "s1".into(), "r1".into(), true, false).await;
    assert!(vm.respond("p1".into(), "s1".into(), "r1".into(), true, false, "token".into(), false, None).await);
}
