//! Submission stays locked through the API request and post-submit refresh.
mod common;

use common::{serve, MemoryStore, Request};
use sam_core::{App, Credentials, ProjectViewModel};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    mpsc, Arc, Mutex,
};
use std::time::Duration;
use tokio::sync::Notify;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn submission_blocks_duplicates_until_the_session_refresh_finishes() {
    let submissions = Arc::new(AtomicUsize::new(0));
    let posted = Arc::new(Notify::new());
    let refreshing = Arc::new(Notify::new());
    let (finish_post, post_gate) = mpsc::channel();
    let (finish_refresh, refresh_gate) = mpsc::channel();
    let post_gate = Mutex::new(post_gate);
    let refresh_gate = Mutex::new(refresh_gate);
    let server = serve(Arc::new({
        let submissions = submissions.clone();
        let posted = posted.clone();
        let refreshing = refreshing.clone();
        move |r: &Request| match (r.method.as_str(), r.path.as_str()) {
            ("POST", "/api/projects/p1/tasks/submit") => {
                submissions.fetch_add(1, Ordering::SeqCst);
                posted.notify_one();
                post_gate.lock().unwrap().recv_timeout(Duration::from_secs(5)).unwrap();
                (202, r#"{"taskId":"t1","sessionId":"s1","branchName":"b","status":"queued"}"#.into())
            }
            ("GET", "/api/projects/p1/sessions?limit=50") => {
                if submissions.load(Ordering::SeqCst) > 0 {
                    refreshing.notify_one();
                    refresh_gate.lock().unwrap().recv_timeout(Duration::from_secs(5)).unwrap();
                }
                (200, r#"{"sessions":[]}"#.into())
            }
            ("GET", "/api/projects/p1/agent-profiles") => (200, r#"{"items":[]}"#.into()),
            ("GET", "/api/projects/p1/agent-profiles/picker") => (200, "{}".into()),
            _ => (404, "{}".into()),
        }
    }))
    .await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let vm = ProjectViewModel::new(App::new(Box::new(store), None));
    vm.load("p1".into()).await;
    let request = tokio::spawn({
        let vm = vm.clone();
        async move { vm.submit_task("Start a chat".into()).await }
    });
    tokio::time::timeout(Duration::from_secs(5), posted.notified()).await.unwrap();
    assert!(vm.state().submitting);
    assert!(vm.submit_task("Duplicate tap".into()).await.is_none());
    finish_post.send(()).unwrap();
    tokio::time::timeout(Duration::from_secs(5), refreshing.notified()).await.unwrap();
    assert!(vm.state().loading);
    assert!(vm.state().submitting, "Send must stay disabled during the refresh");
    assert!(vm.submit_task("Tap during refresh".into()).await.is_none());
    finish_refresh.send(()).unwrap();
    assert_eq!(request.await.unwrap().unwrap().session_id, "s1");
    // The FFI result can arrive before the UI continuation runs. Neither a tap
    // nor an unrelated handoff may unlock the still-visible original draft.
    assert!(vm.state().submitting);
    assert!(vm.submit_task("Tap before navigation".into()).await.is_none());
    vm.finish_submission("unrelated-session".into());
    assert!(vm.state().submitting);
    assert_eq!(submissions.load(Ordering::SeqCst), 1);
    vm.finish_submission("s1".into());
    assert!(!vm.state().submitting);
    assert!(vm.state().submitted_session_id.is_none());
}

#[tokio::test]
async fn failed_submission_unlocks_the_composer_for_retry() {
    let attempts = Arc::new(AtomicUsize::new(0));
    let server = serve(Arc::new({
        let attempts = attempts.clone();
        move |r: &Request| match (r.method.as_str(), r.path.as_str()) {
            ("POST", "/api/projects/p1/tasks/submit") if attempts.fetch_add(1, Ordering::SeqCst) == 0 => {
                (500, r#"{"error":"INTERNAL_ERROR","message":"Try again"}"#.into())
            }
            ("POST", "/api/projects/p1/tasks/submit") => {
                (202, r#"{"taskId":"t1","sessionId":"s1","branchName":"b","status":"queued"}"#.into())
            }
            ("GET", "/api/projects/p1/sessions?limit=50") => (200, r#"{"sessions":[]}"#.into()),
            ("GET", "/api/projects/p1/agent-profiles") => (200, r#"{"items":[]}"#.into()),
            ("GET", "/api/projects/p1/agent-profiles/picker") => (200, "{}".into()),
            _ => (404, "{}".into()),
        }
    }))
    .await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let vm = ProjectViewModel::new(App::new(Box::new(store), None));
    vm.load("p1".into()).await;
    assert!(vm.submit_task("Start a chat".into()).await.is_none());
    assert!(!vm.state().submitting);
    assert!(vm.state().error.is_some());
    let accepted = vm.submit_task("Start a chat".into()).await.unwrap();
    assert!(vm.state().submitting);
    vm.finish_submission(accepted.session_id);
    assert!(!vm.state().submitting);
    assert!(vm.state().error.is_none());
    assert_eq!(attempts.load(Ordering::SeqCst), 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_late_submission_cannot_reopen_the_previous_project() {
    let posted = Arc::new(Notify::new());
    let (finish_post, post_gate) = mpsc::channel();
    let post_gate = Mutex::new(post_gate);
    let server = serve(Arc::new({
        let posted = posted.clone();
        move |r: &Request| {
            if r.method == "POST" && r.path == "/api/projects/p1/tasks/submit" {
                posted.notify_one();
                post_gate.lock().unwrap().recv_timeout(Duration::from_secs(5)).unwrap();
                return (202, r#"{"taskId":"t1","sessionId":"s1","branchName":"b","status":"queued"}"#.into());
            }
            if r.path.ends_with("/sessions?limit=50") {
                (200, r#"{"sessions":[]}"#.into())
            } else if r.path.ends_with("/agent-profiles") {
                (200, r#"{"items":[]}"#.into())
            } else {
                (200, "{}".into())
            }
        }
    }))
    .await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let vm = ProjectViewModel::new(App::new(Box::new(store), None));
    vm.load("p1".into()).await;
    let request = tokio::spawn({
        let vm = vm.clone();
        async move { vm.submit_task("Start a chat".into()).await }
    });
    tokio::time::timeout(Duration::from_secs(5), posted.notified()).await.unwrap();
    vm.finish_submission("s1".into());
    assert!(vm.state().submitting, "An unaccepted session cannot release the lock");
    let switched = tokio::spawn({
        let vm = vm.clone();
        async move { vm.load("p2".into()).await }
    });
    tokio::time::timeout(Duration::from_secs(5), async {
        while vm.state().project_id != "p2" {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    finish_post.send(()).unwrap();
    switched.await.unwrap();
    assert!(request.await.unwrap().is_none(), "Do not navigate away from the new project");
    assert_eq!(vm.state().project_id, "p2");
    assert!(!vm.state().submitting);
    assert!(vm.state().submitted_session_id.is_none());
}
