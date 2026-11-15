//! Transcript -> durable library metadata -> authenticated file bytes.
mod common;
use common::{serve, MemoryStore};
use sam_core::{App, ChatViewModel, Credentials};
use serde_json::json;
use std::sync::{Arc, Mutex};

#[tokio::test]
async fn library_cards_survive_sparse_updates_reload_and_load_authenticated_bytes() {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let seen = requests.clone();
    let server = serve(Arc::new(move |r| {
        assert_eq!(r.header("cookie").as_deref(), Some("session=abc"));
        seen.lock().unwrap().push(r.path.clone());
        match r.path.as_str() {
            "/api/projects/p1/sessions/s1" => (200, json!({
                "session":{"id":"s1","status":"stopped","startedAt":1},
                "messages":[
                    {"id":"a","role":"tool","createdAt":1,"toolMetadata":{"toolCallId":"c1","toolName":"sam-mcp/display_from_library","rawInput":{"fileId":"image","caption":"A small preview"}}},
                    {"id":"b","role":"tool","createdAt":2,"toolMetadata":{"toolCallId":"c1","rawOutput":[{"type":"text","text":"{\"fileId\":\"image\",\"filename\":\"photo.png\",\"mimeType\":\"image/png\",\"sizeBytes\":4}"}]}},
                    {"id":"c","role":"tool","createdAt":3,"toolMetadata":{"toolName":"mcp__sam__upload_to_library","rawOutput":{"id":"pdf","filename":"report.pdf","mimeType":"application/pdf","sizeBytes":10}}},
                    {"id":"d","role":"tool","createdAt":4,"toolMetadata":{"toolName":"display_from_library","rawInput":{"fileId":"gone"},"rawOutput":{"error":"FILE_NOT_FOUND"}}},
                    {"id":"e","role":"tool","createdAt":5,"toolMetadata":{"toolName":"shell","rawOutput":{"fileId":"unsafe"}},"content":"ordinary tool output"}
                ]
            }).to_string()),
            "/api/projects/p1/library/image/download" => (200, "PNG!".into()),
            "/api/projects/p1/library/pdf/download" => (200, "%PDF".into()),
            _ => panic!("unexpected request {}", r.path),
        }
    })).await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let vm = ChatViewModel::new(App::new(Box::new(store), None));
    vm.load("p1".into(), "s1".into()).await;
    let state = vm.state();
    assert_eq!(state.messages.len(), 4);
    let image = state.messages[0].document.as_ref().unwrap();
    assert_eq!(image.filename, "photo.png");
    assert_eq!(image.caption, "A small preview");
    assert_eq!(image.size_bytes, Some(4));
    assert!(state.messages[2].document.as_ref().unwrap().unavailable);
    assert!(state.messages[3].document.is_none());
    assert_eq!(vm.document_bytes("image".into()).await.unwrap(), b"PNG!");
    assert_eq!(vm.document_bytes("pdf".into()).await.unwrap(), b"%PDF");
    assert!(vm.document_bytes("gone".into()).await.is_none());
    assert!(vm.document_bytes("https://example.com".into()).await.is_none());
    vm.refresh().await;
    assert_eq!(vm.state().messages, state.messages);
    assert_eq!(requests.lock().unwrap().len(), 4);
}

#[tokio::test]
async fn unauthorized_file_read_ends_the_session() {
    let server = serve(Arc::new(|r| match r.path.as_str() {
        "/api/projects/p/sessions/s" => (200, json!({"session":{"id":"s","status":"stopped","startedAt":1},"messages":[{"id":"m","role":"tool","toolMetadata":{"toolName":"display_from_library","rawOutput":{"fileId":"f"}}}]}).to_string()),
        _ => (401, "{}".into()),
    })).await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let app = App::new(Box::new(store.clone()), None);
    let vm = ChatViewModel::new(app.clone());
    vm.load("p".into(), "s".into()).await;
    assert!(vm.document_bytes("f".into()).await.is_none());
    assert!(store.0.lock().unwrap().is_none());
}

#[tokio::test]
async fn oversized_download_fails_without_retaining_preview_bytes() {
    let server = serve(Arc::new(|r| match r.path.as_str() {
        "/api/projects/p/sessions/s" => (200, json!({"session":{"id":"s","status":"stopped","startedAt":1},"messages":[{"id":"m","role":"tool","toolMetadata":{"toolName":"display_from_library","rawOutput":{"fileId":"f"}}}]}).to_string()),
        _ => (200, "x".repeat(20 * 1024 * 1024 + 1)),
    })).await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let vm = ChatViewModel::new(App::new(Box::new(store), None));
    vm.load("p".into(), "s".into()).await;
    assert!(vm.document_bytes("f".into()).await.is_none());
    assert!(vm.state().error.is_none());
}
