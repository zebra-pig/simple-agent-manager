//! Project search uses the real view model and authenticated, paginated HTTP.
mod common;

use common::{serve, MemoryStore};
use sam_core::{App, Credentials, ProjectViewModel};
use serde_json::json;
use std::sync::{Arc, Mutex};

#[tokio::test]
async fn searches_all_pages_and_preserves_query_on_refresh() {
    let fail = Arc::new(Mutex::new(false));
    let fail_route = fail.clone();
    let requests = Arc::new(Mutex::new(Vec::new()));
    let log = requests.clone();
    let server = serve(Arc::new(move |r| {
        assert_eq!(r.header("cookie").as_deref(), Some("session=test"));
        log.lock().unwrap().push(r.path.clone());
        match r.path.as_str() {
            // Only two valid rows survive the first 50-row server window.
            "/api/projects/p1/sessions?limit=50" => (
                200,
                json!({
                    "sessions": [{"id":"ABC-123", "topic":"Fix Login", "lastMessageAt":20},
                                 {"id":"untitled", "topic":null, "startedAt":10}], "hasMore":true
                })
                .to_string(),
            ),
            "/api/projects/p1/sessions?limit=50&offset=50" => {
                if *fail_route.lock().unwrap() {
                    return (500, json!({"message":"Try again"}).to_string());
                }
                (200, json!({"sessions":[{"id":"old", "topic":"Café release", "startedAt":1}], "hasMore":false}).to_string())
            }
            "/api/projects/p1/agent-profiles" => (200, r#"{"items":[]}"#.into()),
            "/api/projects/p1/agent-profiles/picker" => (200, "{}".into()),
            _ => (404, "{}".into()),
        }
    }))
    .await;
    let app = App::new(
        Box::new(MemoryStore(Arc::new(Mutex::new(Some(Credentials { server_url: server, session_cookie: "session=test".into() }))))),
        None,
    );
    let vm = ProjectViewModel::new(app);
    vm.load("p1".into()).await;
    assert!(vm.state().error.is_none());
    assert_eq!(vm.state().matching_sessions.len(), 3);
    assert_eq!(vm.state().sessions[0].id, "ABC-123");
    vm.search_sessions("  CAFÉ  ".into());
    assert_eq!(vm.state().matching_sessions[0].id, "old");
    vm.load("p1".into()).await;
    assert_eq!(vm.state().matching_sessions.len(), 1);
    assert_eq!(vm.state().matching_sessions[0].id, "old");
    vm.search_sessions("abc-123".into());
    assert_eq!(vm.state().matching_sessions[0].id, "ABC-123");
    vm.search_sessions("LOGIN".into());
    assert_eq!(vm.state().matching_sessions[0].id, "ABC-123");
    vm.search_sessions("no match".into());
    assert!(vm.state().matching_sessions.is_empty());
    assert_eq!(vm.state().sessions.len(), 3);
    vm.search_sessions(" \n ".into());
    assert_eq!(vm.state().matching_sessions.len(), 3);
    *fail.lock().unwrap() = true;
    vm.load("p1".into()).await;
    assert!(vm.state().error.is_some());
    assert!(!vm.state().loading);
    assert_eq!(vm.state().matching_sessions.len(), 3, "failed refresh retains the full list");
    assert!(requests.lock().unwrap().iter().any(|p| p.ends_with("offset=50")));
}

#[tokio::test]
async fn repeated_page_fails_instead_of_looping_or_claiming_complete_results() {
    let server = serve(Arc::new(|r| {
        if r.path.contains("/sessions?") {
            (200, json!({"sessions":[{"id":"same"}], "hasMore":true}).to_string())
        } else if r.path.ends_with("/agent-profiles") {
            (200, r#"{"items":[]}"#.into())
        } else {
            (200, "{}".into())
        }
    }))
    .await;
    let app = App::new(
        Box::new(MemoryStore(Arc::new(Mutex::new(Some(Credentials { server_url: server, session_cookie: "session=test".into() }))))),
        None,
    );
    let vm = ProjectViewModel::new(app);
    vm.load("p1".into()).await;
    assert!(vm.state().error.is_some());
    assert!(!vm.state().loading);
    assert!(vm.state().sessions.is_empty());
}
