//! SAM's complete private-conversation workflow against the same HTTP contracts as web.
mod common;
use common::{serve, MemoryStore, Request};
use sam_core::*;
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

#[derive(Clone, Default)]
struct PendingStore(Arc<Mutex<Option<AssistantPending>>>);
impl AssistantStore for PendingStore {
    fn load(&self, _: String) -> Option<AssistantPending> {
        self.0.lock().unwrap().clone()
    }
    fn save(&self, _: String, pending: AssistantPending) -> bool {
        *self.0.lock().unwrap() = Some(pending);
        true
    }
    fn clear(&self, _: String) {
        *self.0.lock().unwrap() = None;
    }
}
fn turn(id: &str, key: &str, state: &str) -> Value {
    json!({"id":id,"request_key":key,"message":"Check projects","state":state,"response":"Ready", "actions":[
        {"id":"a1","operation":"sam_work_stop","state":"approval_required","input_json":"{\"projectId\":\"p1\",\"sessionId\":\"s1\"}","result_json":null},
        {"id":"a2","operation":"sam_chat_start","state":"uncertain","input_json":"{}","result_json":null}
    ], "live":{"phase":"working","elapsedMs":400,"text":"Checking…","thinking":null,"activity":[{"id":"read1","operation":"sam_projects_list","state":"completed"}]}})
}
async fn app(route: common::Route) -> Arc<App> {
    let server = serve(route).await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=sam".into() });
    App::new(Box::new(store), None)
}
#[tokio::test]
async fn conversation_retry_restart_history_approvals_stop_and_updates() {
    let log = Arc::new(Mutex::new(Vec::new()));
    let requests = log.clone();
    let posts = Arc::new(Mutex::new(0));
    let count = posts.clone();
    let client = app(Arc::new(move |r: &Request| {
        assert_eq!(r.header("cookie").as_deref(), Some("session=sam"));
        let body: Value = serde_json::from_slice(&r.body).unwrap_or(Value::Null);
        requests.lock().unwrap().push((r.method.clone(), r.path.clone(), body));
        match (r.method.as_str(), r.path.as_str()) {
            ("GET", "/api/sam/settings") => (200, json!({"enabled":true,"available":true}).to_string()),
            ("GET", "/api/sam/turns") => {
                let recorded = *count.lock().unwrap() >= 2;
                (200, json!({"conversationId":"private-u1", "legacyHistoryAvailable":true,
                    "turns": if recorded { vec![turn("t1","request-1","running")] } else { vec![] },
                    "nextCursor":"cursor/a", "work":[{"actionId":"a1","projectId":"p1","taskId":"task1","sessionId":"s1","status":"running","attention":true,"updates":{"unread":2}}]}).to_string())
            },
            ("POST", "/api/sam/turns") => {
                let mut n = count.lock().unwrap(); *n += 1;
                if *n == 1 { (503, json!({"error":"TEMPORARY","message":"Try again"}).to_string()) }
                else { (202, json!({"turn":turn("t1","request-1","running")}).to_string()) }
            },
            ("GET", "/api/sam/turns?before=cursor%2Fa") => (200, json!({"turns":[turn("old","old-key","completed")],"nextCursor":null}).to_string()),
            ("GET", "/api/sam/conversations/private-u1/messages") => (200, json!({"messages":[{"id":"operator:hidden","role":"assistant","content":"hidden"},{"id":"m1","role":"user","content":"Earlier"}],"nextCursor":12}).to_string()),
            ("GET", "/api/sam/conversations/private-u1/messages?before=12") => (200, json!({"messages":[{"id":"m0","role":"assistant","content":"Oldest"}],"nextCursor":null}).to_string()),
            ("POST", "/api/sam/actions/a1/confirm" | "/api/sam/actions/a2/reconcile" | "/api/sam/turns/t1/cancel" | "/api/sam/updates/a1/seen") => (200, "{}".into()),
            _ => (404, "{}".into()),
        }
    })).await;
    client.refresh_assistant_settings().await;
    assert!(client.state().assistant_enabled);
    let store = PendingStore::default();
    let vm = AssistantViewModel::new(client.clone(), Box::new(store.clone()));
    vm.refresh().await;
    assert!(vm.state().enabled && vm.state().loaded);
    vm.send("Check projects".into(), "request-1".into()).await;
    assert!(vm.state().error.is_some());
    assert_eq!(store.0.lock().unwrap().as_ref().unwrap().request_key, "request-1");
    drop(vm);
    let vm = AssistantViewModel::new(client, Box::new(store.clone()));
    vm.refresh().await;
    assert_eq!(vm.state().pending.as_ref().unwrap().message, "Check projects");
    vm.send("must not replace uncertain request".into(), "different-key".into()).await;
    assert!(vm.state().pending.is_none() && store.0.lock().unwrap().is_none());
    assert_eq!(vm.state().turns[0].live.as_ref().unwrap().text, "Checking…");
    vm.send("blocked while running".into(), "key-3".into()).await;
    assert_eq!(*posts.lock().unwrap(), 2);
    vm.load_older().await;
    vm.refresh().await;
    assert_eq!(vm.state().turns.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), ["old", "t1"]);
    assert!(vm.state().next_cursor.is_none());
    vm.load_earlier().await;
    vm.load_earlier().await;
    assert_eq!(vm.state().earlier.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["m0", "m1"]);
    vm.confirm("a1".into(), true).await;
    vm.confirm("a1".into(), false).await;
    vm.confirm("unknown".into(), true).await;
    vm.reconcile("a2".into()).await;
    vm.stop().await;
    vm.mark_seen("a1".into()).await;
    let log = log.lock().unwrap();
    let sends: Vec<_> = log.iter().filter(|(m, p, _)| m == "POST" && p == "/api/sam/turns").collect();
    assert_eq!(sends[0].2, sends[1].2);
    assert!(log.iter().any(|(_, p, b)| p.ends_with("a1/confirm") && b["approved"] == true));
    assert!(log.iter().any(|(_, p, b)| p.ends_with("a1/confirm") && b["approved"] == false));
    assert!(!log.iter().any(|(_, p, _)| p.contains("unknown")));
    for endpoint in ["/api/sam/actions/a2/reconcile", "/api/sam/turns/t1/cancel", "/api/sam/updates/a1/seen"] {
        assert!(log.iter().any(|(m, p, _)| m == "POST" && p == endpoint));
    }
}
#[tokio::test]
async fn disabled_or_unavailable_never_loads_or_sends_conversation() {
    for (enabled, available) in [(false, true), (true, false)] {
        let client = app(Arc::new(move |r| {
            assert_eq!(r.path, "/api/sam/settings");
            (200, json!({"enabled":enabled,"available":available}).to_string())
        }))
        .await;
        client.refresh_assistant_settings().await;
        assert!(!client.state().assistant_enabled);
        let vm = AssistantViewModel::new(client, Box::<PendingStore>::default());
        vm.refresh().await;
        vm.send("Hello".into(), "key".into()).await;
        assert!(!vm.state().enabled && vm.state().turns.is_empty());
    }
}
#[test]
fn receipt_links_are_safe_and_keep_resource_identity() {
    let action = AssistantAction { input_json: r#"{"projectId":"p/a","sessionId":"s/b"}"#.into(), ..Default::default() };
    assert_eq!(assistant_action_link(action.clone()).as_deref(), Some("/projects/p%2Fa/chat/s%2Fb"));
    for link in ["javascript:alert(1)", "//evil.test/path", "file:///etc/passwd"] {
        let invalid = AssistantAction { input_json: "{}".into(), result_json: Some(json!({"link":link}).to_string()), ..action.clone() };
        assert!(assistant_action_link(invalid).is_none());
    }
    assert!(assistant_action_link(AssistantAction { available: Some(false), ..action }).is_none());
}

#[tokio::test]
async fn signed_out_view_model_cannot_read_or_mutate_a_private_conversation() {
    let client = app(Arc::new(|r| match r.path.as_str() {
        "/api/sam/settings" => (200, json!({"enabled":true,"available":true}).to_string()),
        "/api/sam/turns" => (200, json!({"conversationId":"private","turns":[turn("t1","key","completed")]}).to_string()),
        "/api/auth/sign-out" => (200, "{}".into()),
        unexpected => panic!("unexpected request after sign-out: {unexpected}"),
    }))
    .await;
    let store = PendingStore::default();
    let vm = AssistantViewModel::new(client.clone(), Box::new(store));
    vm.refresh().await;
    assert_eq!(vm.state().turns.len(), 1);
    client.sign_out().await;
    vm.refresh().await;
    assert!(vm.state().turns.is_empty());
    assert!(!vm.state().enabled && !client.state().assistant_enabled);
    vm.send("must not send".into(), "new-key".into()).await;
    vm.confirm("a1".into(), true).await;
}

#[tokio::test]
async fn voice_upload_uses_authenticated_multipart_and_returns_a_draft() {
    let client = app(Arc::new(|r| match r.path.as_str() {
        "/api/sam/settings" => (200, json!({"enabled":true,"available":true}).to_string()),
        "/api/sam/turns" => (200, json!({"conversationId":"private","turns":[]}).to_string()),
        "/api/transcribe" => {
            assert_eq!(r.method, "POST");
            assert_eq!(r.header("cookie").as_deref(), Some("session=sam"));
            assert!(r.header("content-type").unwrap().starts_with("multipart/form-data; boundary="));
            let body = String::from_utf8_lossy(&r.body);
            assert!(body.contains("name=\"audio\"; filename=\"voice.m4a\""));
            assert!(body.contains("audio/mp4"));
            (200, json!({"text":"What needs attention?"}).to_string())
        }
        unexpected => panic!("transcription must not send a turn: {unexpected}"),
    }))
    .await;
    let vm = AssistantViewModel::new(client, Box::<PendingStore>::default());
    vm.refresh().await;
    assert_eq!(vm.transcribe(vec![1, 2, 3]).await.as_deref(), Some("What needs attention?"));
    assert!(vm.transcribe(vec![]).await.is_none());
    assert!(vm.state().turns.is_empty() && vm.state().pending.is_none());
}
#[test]
fn markdown_formats_text_without_executing_html_or_unsafe_links() {
    let html = assistant_markdown_html(
        "**Bold** and `code`\n\n- item\n\n<script>alert(1)</script>\n\n[bad](javascript:alert) [chat](/projects/p/chat/s)".into(),
    );
    assert!(html.contains("<strong>Bold</strong>") && html.contains("<code>code</code>") && html.contains("<li>item</li>"));
    assert!(html.contains("&lt;script&gt;") && !html.contains("href=\"javascript:"));
    assert!(html.contains("href=\"/projects/p/chat/s\""));
}

#[tokio::test]
async fn device_storage_failure_preserves_the_draft_and_never_sends() {
    struct UnavailableStore;
    impl AssistantStore for UnavailableStore {
        fn load(&self, _: String) -> Option<AssistantPending> {
            None
        }
        fn save(&self, _: String, _: AssistantPending) -> bool {
            false
        }
        fn clear(&self, _: String) {}
    }
    let client = app(Arc::new(|r| match (r.method.as_str(), r.path.as_str()) {
        ("GET", "/api/sam/settings") => (200, json!({"enabled":true,"available":true}).to_string()),
        ("GET", "/api/sam/turns") => (200, json!({"conversationId":"private","turns":[]}).to_string()),
        unexpected => panic!("must persist before any send: {unexpected:?}"),
    }))
    .await;
    let vm = AssistantViewModel::new(client, Box::new(UnavailableStore));
    vm.refresh().await;
    vm.send("Keep my draft".into(), "request-1".into()).await;
    assert_eq!(vm.state().pending.unwrap().message, "Keep my draft");
    assert!(vm.state().error.is_some() && !vm.state().busy);
}
