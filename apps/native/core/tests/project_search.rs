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

#[tokio::test]
async fn background_refresh_discovers_spawned_sessions_preserves_search_and_retries() {
    let spawned = Arc::new(Mutex::new(false));
    let fail = Arc::new(Mutex::new(false));
    let requests = Arc::new(Mutex::new(Vec::new()));
    let (remote_spawned, remote_fail, log) = (spawned.clone(), fail.clone(), requests.clone());
    let server = serve(Arc::new(move |r| {
        log.lock().unwrap().push(r.path.clone());
        if r.path.contains("/sessions?") {
            if *remote_fail.lock().unwrap() {
                return (503, json!({"message":"Temporarily unavailable"}).to_string());
            }
            let mut sessions = vec![json!({"id":"parent", "topic":"Parent agent", "startedAt":1})];
            if *remote_spawned.lock().unwrap() {
                sessions.push(json!({"id":"child", "topic":"Child agent", "startedAt":2}));
            }
            (200, json!({"sessions":sessions, "hasMore":false}).to_string())
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
    assert_eq!(vm.state().sessions.len(), 1);
    vm.search_sessions("child".into());
    assert!(vm.state().matching_sessions.is_empty());
    requests.lock().unwrap().clear();
    *spawned.lock().unwrap() = true;
    vm.refresh().await;
    assert_eq!(vm.state().sessions[0].id, "child");
    assert_eq!(vm.state().matching_sessions[0].id, "child");
    assert_eq!(vm.state().search_query, "child");
    assert!(!vm.state().loading);
    assert_eq!(*requests.lock().unwrap(), vec!["/api/projects/p1/sessions?limit=50"]);

    *fail.lock().unwrap() = true;
    vm.refresh().await;
    assert!(vm.state().error.is_some());
    assert_eq!(vm.state().sessions.len(), 2);
    assert_eq!(vm.state().matching_sessions[0].id, "child");
    *fail.lock().unwrap() = false;
    vm.refresh().await;
    assert!(vm.state().error.is_none());
    assert_eq!(vm.state().matching_sessions[0].id, "child");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn delayed_poll_cannot_overwrite_a_newer_explicit_load() {
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Condvar,
    };
    use std::time::Duration;
    let count = Arc::new(AtomicUsize::new(0));
    let release = Arc::new((Mutex::new(false), Condvar::new()));
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (remote_count, remote_release) = (count.clone(), release.clone());
    let server = serve(Arc::new(move |r| {
        if r.path.contains("/sessions?") {
            let read = remote_count.fetch_add(1, Ordering::SeqCst);
            if read == 1 {
                started_tx.send(()).unwrap();
                tokio::task::block_in_place(|| {
                    let (lock, signal) = &*remote_release;
                    let (_guard, timeout) =
                        signal.wait_timeout_while(lock.lock().unwrap(), Duration::from_secs(5), |ready| !*ready).unwrap();
                    assert!(!timeout.timed_out(), "test must release the delayed poll");
                });
            }
            let id = if read >= 2 { "new-agent" } else { "old-agent" };
            (200, json!({"sessions":[{"id":id}], "hasMore":false}).to_string())
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
    let poll_model = vm.clone();
    let poll = tokio::spawn(async move { poll_model.refresh().await });
    tokio::task::spawn_blocking(move || started_rx.recv_timeout(Duration::from_secs(5)))
        .await
        .unwrap()
        .expect("poll must reach HTTP server");
    vm.load("p1".into()).await;
    assert_eq!(vm.state().sessions[0].id, "new-agent");
    let (lock, signal) = &*release;
    *lock.lock().unwrap() = true;
    signal.notify_all();
    poll.await.unwrap();
    assert_eq!(vm.state().sessions[0].id, "new-agent", "older poll must not roll back newer data");
}

#[tokio::test]
async fn recent_refresh_is_one_page_and_keeps_older_searchable_sessions() {
    let reads = Arc::new(Mutex::new(Vec::new()));
    let refreshed = Arc::new(Mutex::new(false));
    let (log, remote_refreshed) = (reads.clone(), refreshed.clone());
    let server = serve(Arc::new(move |r| {
        log.lock().unwrap().push(r.path.clone());
        if r.path.ends_with("offset=50") {
            (200, json!({"sessions":[{"id":"old", "topic":"Older work", "startedAt":1}], "hasMore":false}).to_string())
        } else if r.path.contains("/sessions?") {
            let id = if *remote_refreshed.lock().unwrap() { "child" } else { "parent" };
            (200, json!({"sessions":[{"id":id, "startedAt":2}], "hasMore":true}).to_string())
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
    vm.search_sessions("older".into());
    reads.lock().unwrap().clear();
    *refreshed.lock().unwrap() = true;
    vm.refresh().await;
    assert_eq!(*reads.lock().unwrap(), vec!["/api/projects/p1/sessions?limit=50"]);
    assert_eq!(vm.state().sessions.len(), 3);
    assert_eq!(vm.state().matching_sessions[0].id, "old");
    assert!(vm.state().sessions.iter().any(|s| s.id == "child"));
}
