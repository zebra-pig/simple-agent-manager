//! The chat screen against a scripted stand-in for the SAM API: the timeline
//! it builds from stored rows, and a follow-up's trip through the outbox.

mod common;

use std::sync::{Arc, Mutex};

use common::{serve, MemoryStore, Request};
use sam_core::{App, ChatContent, ChatViewModel, Credentials, UserError};
use serde_json::{json, Value};

struct Server {
    rows: Mutex<Vec<Value>>,
    /// The next prompt fails with this status.
    fail_prompt: Mutex<Option<u16>>,
    /// Prompts the server took, stored on the next GET (as durable delivery does).
    pending: Mutex<Vec<String>>,
}

async fn chat(server: Arc<Server>) -> Arc<ChatViewModel> {
    let s = server.clone();
    let origin = serve(Arc::new(move |r: &Request| match (r.method.as_str(), r.path.as_str()) {
        ("GET", "/api/projects/p1/sessions/s1") => {
            let mut rows = s.rows.lock().unwrap();
            for text in s.pending.lock().unwrap().drain(..) {
                let n = rows.len();
                rows.push(json!({"id": format!("r{n}"), "role": "user", "content": text, "createdAt": 100 + n}));
            }
            let body = json!({
                "session": {"id": "s1", "status": "active", "isIdle": false, "startedAt": 1},
                "messages": *rows,
                "hasMore": true,
                "state": {"activity": "prompting", "activityAt": 1},
            });
            (200, body.to_string())
        }
        ("POST", "/api/projects/p1/sessions/s1/prompt") => {
            if let Some(status) = s.fail_prompt.lock().unwrap().take() {
                return (status, r#"{"error":"CONFLICT","message":"The agent is busy"}"#.into());
            }
            let body: Value = serde_json::from_slice(&r.body).unwrap();
            s.pending.lock().unwrap().push(body["content"].as_str().unwrap().to_owned());
            (202, r#"{"success":true}"#.into())
        }
        _ => (404, r#"{"error":"NOT_FOUND","message":"Not found"}"#.into()),
    }))
    .await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: origin, session_cookie: "session=abc".into() });
    let vm = ChatViewModel::new(App::new(Box::new(store), None));
    vm.load("p1".into(), "s1".into()).await;
    vm
}

#[tokio::test]
async fn builds_the_timeline_and_follows_a_reply_through_the_outbox() {
    let server = Arc::new(Server {
        rows: Mutex::new(vec![
            json!({"id": "u1", "role": "user", "content": "ok", "createdAt": 1}),
            json!({"id": "a1", "role": "assistant", "content": "Done. Anything else?", "createdAt": 2}),
            json!({"id": "c1", "role": "tool", "content": "(tool call)", "createdAt": 3,
                   "toolMetadata": {"toolCallId": "x", "title": "`ls`", "kind": "execute", "status": "in_progress"}}),
        ]),
        fail_prompt: Mutex::new(None),
        pending: Mutex::new(vec![]),
    });
    let vm = chat(server.clone()).await;
    let state = vm.state();
    assert!(state.working && state.has_more && !state.loading);
    assert_eq!(state.items.len(), 3);
    let ChatContent::Activity { summary, .. } = &state.items[2].content else { panic!("{:?}", state.items[2]) };
    assert!(summary.live);
    assert_eq!(summary.live_title.as_deref(), Some("ls"));

    // Same text as an earlier message: the outbox still waits for the new one.
    assert!(vm.send("ok".into()).await);
    let state = vm.state();
    assert!(state.outbox.is_empty(), "the refresh after sending found it: {:?}", state.outbox);
    assert_eq!(state.items.iter().filter(|i| i.content == ChatContent::User { text: "ok".into() }).count(), 2);

    // A failed send leaves the outbox and reports why.
    *server.fail_prompt.lock().unwrap() = Some(409);
    assert!(!vm.send("again".into()).await);
    let state = vm.state();
    assert!(state.outbox.is_empty() && !state.sending);
    assert_eq!(state.error, Some(UserError::Server { message: "The agent is busy".into() }));

    // Blank text sends nothing.
    assert!(!vm.send("  ".into()).await);
}

#[tokio::test]
async fn rejects_duplicate_sends_and_does_not_leak_outbox_across_projects() {
    let server = Arc::new(Server { rows: Mutex::new(vec![]), fail_prompt: Mutex::new(None), pending: Mutex::new(vec![]) });
    let vm = chat(server.clone()).await;
    let (first, duplicate) = tokio::join!(vm.send("first".into()), vm.send("duplicate".into()));
    assert!(first);
    assert!(!duplicate);
    assert_eq!(server.rows.lock().unwrap().len(), 1);

    // Session IDs alone are not sufficient: another project can use the same ID.
    let (sent, ()) = tokio::join!(vm.send("old project".into()), vm.load("p2".into(), "s1".into()));
    assert!(sent);
    let state = vm.state();
    assert_eq!(state.project_id, "p2");
    assert!(state.outbox.is_empty());
    assert!(!state.sending);
}
