mod common;
use common::{serve, MemoryStore, Request};
use sam_core::{App, ChatContent, ChatViewModel, Credentials};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct History {
    rows: Vec<Value>,
    fail_older: bool,
    stall: bool,
    cursors: Vec<Value>,
    before_requests: usize,
    after_requests: usize,
    delay: Arc<std::sync::atomic::AtomicBool>,
    started: Arc<std::sync::atomic::AtomicUsize>,
}
fn row(id: &str, at: i64, sequence: i64, role: &str, content: &str) -> Value {
    json!({"id": id, "createdAt": at, "sequence": sequence, "role": role, "content": content})
}
fn position(row: &Value) -> (i64, i64, &str) {
    (row["createdAt"].as_i64().unwrap(), row["sequence"].as_i64().unwrap(), row["id"].as_str().unwrap())
}
async fn model(state: Arc<Mutex<History>>) -> Arc<ChatViewModel> {
    let origin = serve(Arc::new(move |r: &Request| {
        let url = url::Url::parse(&format!("http://localhost{}", r.path)).unwrap();
        if r.method == "POST" {
            return (202, "{}".into());
        }
        if !url.path().starts_with("/api/projects/p/sessions/") {
            return (404, "{}".into());
        }
        let (delay, started) = {
            let state = state.lock().unwrap();
            (state.delay.clone(), state.started.clone())
        };
        if delay.load(std::sync::atomic::Ordering::SeqCst) {
            started.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            std::thread::sleep(std::time::Duration::from_millis(150));
        }
        let session = url.path().rsplit('/').next().unwrap();
        let query = url.query_pairs().find(|(key, _)| key == "before" || key == "after");
        let mut state = state.lock().unwrap();
        let mut rows = state.rows.clone();
        rows.sort_by(|a, b| position(a).cmp(&position(b)));
        let mut forward = false;
        if let Some((key, cursor)) = query {
            let cursor: Value = serde_json::from_str(&cursor).unwrap();
            let bound = (cursor[0].as_i64().unwrap(), cursor[1].as_i64().unwrap(), cursor[2].as_str().unwrap());
            state.cursors.push(cursor.clone());
            if key == "before" {
                state.before_requests += 1;
                if state.fail_older {
                    state.fail_older = false;
                    return (503, "{}".into());
                }
                if state.stall {
                    return (
                        200,
                        json!({"session":{"id":session,"status":"active","startedAt":0},"messages":[],"hasMore":true}).to_string(),
                    );
                }
                rows.retain(|row| position(row) < bound);
            } else {
                state.after_requests += 1;
                forward = true;
                rows.retain(|row| position(row) > bound);
            }
        }
        let more = rows.len() > 2;
        if forward {
            rows.truncate(2);
        } else {
            rows = rows.into_iter().rev().take(2).collect();
            rows.reverse();
        }
        (200, json!({"session":{"id":session,"status":"active","startedAt":0},"messages":rows,"hasMore":more}).to_string())
    }))
    .await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: origin, session_cookie: "session=fixture".into() });
    let vm = ChatViewModel::new(App::new(Box::new(store), None));
    vm.load("p".into(), "s".into()).await;
    vm
}
fn ids(vm: &ChatViewModel) -> Vec<String> {
    vm.state().items.into_iter().map(|item| item.id).collect()
}

#[tokio::test]
async fn pages_all_tied_timestamps_without_duplicates_and_retains_history_on_poll() {
    let state = Arc::new(Mutex::new(History {
        rows: (0..7).map(|n| row(&format!("r{n}"), 100, n, "user", &format!("Message {n}"))).collect(),
        ..Default::default()
    }));
    let vm = model(state.clone()).await;
    assert_eq!(ids(&vm), ["r5", "r6"]);
    while vm.state().has_more {
        vm.load_older().await;
    }
    assert_eq!(ids(&vm), (0..7).map(|n| format!("r{n}")).collect::<Vec<_>>());
    assert_eq!(state.lock().unwrap().before_requests, 3);
    assert_eq!(state.lock().unwrap().cursors[0], json!([100, 5, "r5"]));
    vm.refresh().await;
    assert_eq!(ids(&vm).len(), 7);
    assert!(!vm.state().has_more);
    state.lock().unwrap().rows.push(row("r7", 100, 7, "user", "Latest"));
    vm.refresh().await;
    assert_eq!(ids(&vm).len(), 8);
    assert!(!vm.state().has_more);
    vm.load_older().await;
    assert_eq!(state.lock().unwrap().before_requests, 3);
}

#[tokio::test]
async fn recovers_failed_or_stalled_pages_without_losing_the_cursor() {
    let state = Arc::new(Mutex::new(History {
        rows: (0..4).map(|n| row(&format!("r{n}"), 10, n, "user", "Text")).collect(),
        fail_older: true,
        ..Default::default()
    }));
    let vm = model(state.clone()).await;
    vm.load_older().await;
    assert!(vm.state().history_error.is_some());
    assert!(!vm.state().loading_history);
    assert_eq!(ids(&vm), ["r2", "r3"]);
    state.lock().unwrap().stall = true;
    vm.load_older().await;
    assert!(vm.state().history_error.is_some());
    assert!(vm.state().has_more);
    state.lock().unwrap().stall = false;
    vm.load_older().await;
    assert!(vm.state().history_error.is_none());
    assert_eq!(ids(&vm), ["r0", "r1", "r2", "r3"]);
}

#[tokio::test]
async fn polling_drains_missed_forward_pages_instead_of_leaving_a_gap() {
    let state = Arc::new(Mutex::new(History { rows: vec![row("r0", 1, 0, "user", "Start")], ..Default::default() }));
    let vm = model(state.clone()).await;
    for n in 1..8 {
        state.lock().unwrap().rows.push(row(&format!("r{n}"), 1, n, "user", "Next"));
    }
    vm.refresh().await;
    assert_eq!(ids(&vm), (0..8).map(|n| format!("r{n}")).collect::<Vec<_>>());
    assert_eq!(state.lock().unwrap().after_requests, 4);
    assert!(!vm.state().has_more);
}

#[tokio::test]
async fn streaming_chunks_join_across_history_boundaries_and_old_repeats_are_not_receipts() {
    let state = Arc::new(Mutex::new(History {
        rows: vec![row("old", 1, 0, "user", "Repeat"), row("a1", 2, 0, "assistant", "Hello "), row("a2", 2, 1, "assistant", "world")],
        ..Default::default()
    }));
    let vm = model(state.clone()).await;
    assert!(vm.send("Repeat".into()).await);
    vm.load_older().await;
    vm.refresh().await;
    assert_eq!(vm.state().outbox.len(), 1, "Earlier matching text is not the new prompt echo");
    assert!(vm.state().items.iter().any(|item| matches!(&item.content, ChatContent::Agent {text, ..} if text == "Hello world")));
    state.lock().unwrap().rows.push(row("new", 3, 0, "user", "Repeat"));
    vm.refresh().await;
    assert!(vm.state().outbox.is_empty());
    vm.load("p".into(), "different".into()).await;
    assert_eq!(ids(&vm), ["a2", "new"], "Switching sessions resets retained history");
}

#[tokio::test]
async fn concurrent_older_loads_share_one_request_and_id_breaks_cursor_ties() {
    let state = Arc::new(Mutex::new(History {
        rows: (0..6).map(|n| row(&format!("r{n}"), 100, 0, "user", "Same timestamp and sequence")).collect(),
        ..Default::default()
    }));
    let vm = model(state.clone()).await;
    tokio::join!(vm.load_older(), vm.load_older());
    assert_eq!(state.lock().unwrap().before_requests, 1);
    assert_eq!(ids(&vm), ["r2", "r3", "r4", "r5"]);
    vm.load_older().await;
    assert_eq!(ids(&vm), ["r0", "r1", "r2", "r3", "r4", "r5"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cancelled_requests_can_be_retried_after_navigation() {
    use std::sync::atomic::Ordering::SeqCst;
    let state = Arc::new(Mutex::new(History {
        rows: (0..5).map(|n| row(&format!("r{n}"), 100, n, "user", "Message")).collect(),
        ..Default::default()
    }));
    let vm = model(state.clone()).await;
    let (delay, started) = {
        let state = state.lock().unwrap();
        (state.delay.clone(), state.started.clone())
    };
    delay.store(true, SeqCst);
    let refreshing = vm.clone();
    let task = tokio::spawn(async move { refreshing.refresh().await });
    while started.load(SeqCst) < 1 {
        tokio::time::sleep(std::time::Duration::from_millis(1)).await;
    }
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());
    delay.store(false, SeqCst);
    state.lock().unwrap().rows.push(row("r5", 100, 5, "user", "Latest"));
    vm.refresh().await;
    assert!(ids(&vm).contains(&"r5".into()), "Cancelled refresh must not leave polling busy forever");
    delay.store(true, SeqCst);
    let older = vm.clone();
    let task = tokio::spawn(async move { older.load_older().await });
    while started.load(SeqCst) < 2 {
        tokio::time::sleep(std::time::Duration::from_millis(1)).await;
    }
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());
    assert!(!vm.state().loading_history);
    delay.store(false, SeqCst);
    vm.load_older().await;
    assert_eq!(ids(&vm), ["r1", "r2", "r3", "r4", "r5"]);
}
