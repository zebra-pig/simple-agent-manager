//! Capability test: authenticated session -> files -> source and staged diff ->
//! history -> VM and provider limits, through the same proxies used by web.
mod common;
use common::{serve, MemoryStore};
use sam_core::{App, ChatToolsViewModel, ChatViewModel, CodeKind, Credentials};
use serde_json::json;
use std::sync::Arc;

#[tokio::test]
async fn session_tools_follow_the_web_contract() {
    let server = serve(Arc::new(|r| {
        assert_eq!(r.header("cookie").as_deref(), Some("session=abc"));
        let body = match r.path.as_str() {
            "/api/projects/p/sessions/s" => json!({"session":{"id":"s", "workspaceId":"w", "agentSessionId":"a", "viewerAccess":"owner", "status":"active", "task":{"id":"t", "status":"in_progress"}},"messages":[]}),
            "/api/projects/p/sessions/s/files/list?path=." => json!({"path":".","entries":[{"name":"test file.rs", "type":"file", "size":8},{"name":"src", "type":"dir", "size":0}]}),
            "/api/projects/p/sessions/s/files/view?path=test+file.rs" => json!({"filePath":"test file.rs","content":"one\ntwo\n"}),
            "/api/projects/p/sessions/s/git/status" => json!({"staged":[{"path":"test file.rs","status":"R","oldPath":"old.rs"}],"unstaged":[{"path":"test file.rs","status":"M"}],"untracked":[{"path":"new.rs","status":"?"}]}),
            "/api/projects/p/sessions/s/git/diff?path=test+file.rs&staged=true" => json!({"filePath":"test file.rs", "diff":"diff --git a/old.rs b/test file.rs\n--- a/old.rs\n+++ b/test file.rs\n@@ -9,2 +10,2 @@\n same\n-old\n+new\n\\ No newline at end of file\n"}),
            "/api/projects/p/sessions/s/resource-timeline" => json!({"collection":"collected","omittedChunkCount":2,"chunks":[{"workspaceId":"w", "rollup":{"start":[1000,61000,121000],"cpuMeanCores":[0.25,null,1.5],"memoryMeanBytes":[1048576,2097152,3145728],"ioReadBytes":[0,5,8],"ioWriteBytes":[0,9,null]}},{"workspaceId":"legacy","rollup":null}]}),
            "/api/workspaces/w" => json!({"id":"w","name":"Workspace","nodeId":"n","status":"running","branch":"feature/test","vmLocation":"fsn1"}),
            "/api/nodes/n" => json!({"id":"n","name":"VM","status":"running","healthStatus":"healthy","providerInstanceVcpuCount":4,"providerInstanceMemoryMb":8192}),
            "/api/projects/p/credential-limits?agentSessionId=a" => json!({"credentials":[{"windows":[{"provider":"openai","windowType":"codex.primary","status":"allowed","utilizationPercent":25.0,"remainingAmount":75.0,"limitAmount":100.0,"resetsAt":999999,"observedAt":5000}]}]}),
            "/api/projects/p/tasks/t/status" => { assert_eq!(r.method,"POST"); assert_eq!(serde_json::from_slice::<serde_json::Value>(&r.body).unwrap()["status"],"completed"); json!({"id":"t"}) },
            _ => return (404, "{}".into()),
        };
        (200, body.to_string())
    })).await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let app = App::new(Box::new(store), None);
    let chat = ChatViewModel::new(app.clone());
    chat.load("p".into(), "s".into()).await;
    let session = chat.state().session.unwrap();
    let tools = ChatToolsViewModel::new(app);
    tools.load("p".into(), "s".into());
    tools.browse(".".into()).await;
    assert_eq!(tools.state().entries[0].kind, "dir");
    tools.open_file("test file.rs".into(), false, false).await;
    assert_eq!(tools.state().lines[1].new_number, Some(2));
    assert_eq!(tools.state().path, "."); // back from a file still lists its parent
    tools.git_status().await;
    let changes = tools.state().changes;
    assert!(changes[0].staged);
    assert_eq!(changes[0].old_path.as_deref(), Some("old.rs"));
    assert!(!changes[1].staged);
    assert!(changes[2].untracked);
    tools.open_file(changes[0].path.clone(), true, true).await;
    let lines = tools.state().lines;
    assert_eq!(lines[4].old_number, Some(9));
    assert_eq!(lines[5].kind, CodeKind::Removed);
    assert_eq!(lines[5].old_number, Some(10));
    assert_eq!(lines[6].kind, CodeKind::Added);
    assert_eq!(lines[6].new_number, Some(11));
    assert_eq!(lines[7].kind, CodeKind::Header);
    tools.resources().await;
    assert_eq!(tools.state().points.len(), 3);
    assert_eq!(tools.state().points[1].cpu_cores, None);
    assert_eq!(tools.state().points[2].cpu_cores, Some(1.5));
    assert_eq!(tools.state().omitted_chunks, 2);
    tools.details(session.workspace_id, session.agent_session_id).await;
    assert_eq!(tools.state().node.unwrap().provider_instance_vcpu_count, Some(4));
    assert_eq!(tools.state().limits[0].remaining_amount, Some(75.0));
    assert!(tools.state().error.is_none());
    chat.end_task().await;
    assert!(chat.state().error.is_none());
    // Failed navigation keeps the last successful listing, and reports a retryable error.
    tools.browse("missing".into()).await;
    assert!(tools.state().error.is_some());
    assert_eq!(tools.state().entries.len(), 2);
    tools.load("other".into(), "other".into());
    assert!(tools.state().entries.is_empty());
    assert!(tools.state().node.is_none());
}

#[test]
fn diff_zero_ranges_and_header_like_content_keep_correct_numbers() {
    let rows = sam_core::code_lines("@@ -1,2 +0,0 @@\n---text\n-other\n@@ -0,0 +1,1 @@\n+++text", true);
    assert_eq!(rows[1].kind, CodeKind::Removed);
    assert_eq!(rows[1].old_number, Some(1));
    assert_eq!(rows[2].old_number, Some(2));
    assert_eq!(rows[4].kind, CodeKind::Added);
    assert_eq!(rows[4].new_number, Some(1));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 3)]
async fn later_navigation_wins_over_a_slow_response() {
    let server = serve(Arc::new(|r| {
        let slow = r.path.contains("path=slow");
        if slow {
            std::thread::sleep(std::time::Duration::from_millis(150));
        }
        (200, json!({"path":if slow {"slow"} else {"fast"},"entries":[]}).to_string())
    }))
    .await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let tools = ChatToolsViewModel::new(App::new(Box::new(store), None));
    tools.load("p".into(), "s".into());
    let first = tools.clone();
    let slow = tokio::spawn(async move { first.browse("slow".into()).await });
    tokio::time::sleep(std::time::Duration::from_millis(30)).await;
    tools.browse("fast".into()).await;
    slow.await.unwrap();
    assert_eq!(tools.state().path, "fast");
    assert!(!tools.state().loading);
}
