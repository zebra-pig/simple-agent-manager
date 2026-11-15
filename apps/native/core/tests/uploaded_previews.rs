mod common;
use common::{serve, MemoryStore, Request};
use sam_core::{App, ChatContent, ChatViewModel, Credentials};
use serde_json::json;
use std::sync::{Arc, Mutex};

const UPLOAD: &str = "01M7FSHXZ07Z2V7660M26N06SY";
const COOKIE: &str = "session=fixture";
async fn fixture(
    original: u16,
    copied: u16,
    filename: &str,
    payload: String,
) -> (Arc<ChatViewModel>, MemoryStore, Arc<Mutex<Vec<String>>>) {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let observed = requests.clone();
    let filename = filename.to_owned();
    let origin = serve(Arc::new(move |request: &Request| {
        let url = url::Url::parse(&format!("http://localhost{}", request.path)).unwrap();
        match url.path() {
            "/api/projects/p/sessions/s" => {
                let prompt = format!("Look at this\n\n## Attached Files\n\nThe following files have been uploaded to the workspace:\n- `/workspaces/.private/{UPLOAD}/{filename}` (4 bytes, image/png)\n\nThese are absolute paths inside your workspace container, outside the repository. Open the exact paths listed above to read the attachments; do not look for them relative to the repository.");
                (200, json!({"session":{"id":"s","status":"active","startedAt":1,"isMine":true}, "messages":[{"id":"m","role":"user","createdAt":1,"content":prompt}]}).to_string())
            }
            "/api/report-issue/config" => (200, json!({"enabled":false}).to_string()),
            "/api/notifications" => (200, json!({"notifications":[],"nextCursor":null}).to_string()),
            "/api/projects/p/sessions/s/files/raw" => {
                assert_eq!(request.header("cookie").as_deref(), Some(COOKIE));
                assert_eq!(url.query_pairs().collect::<Vec<_>>(), vec![("path".into(), format!("/workspaces/.private/{UPLOAD}/{filename}").into())]);
                observed.lock().unwrap().push("workspace".into());
                (copied, payload.clone())
            }
            path if path.starts_with("/api/projects/p/tasks/uploads/") => {
                assert_eq!(request.header("cookie").as_deref(), Some(COOKIE));
                observed.lock().unwrap().push("original".into());
                (original, payload.clone())
            }
            _ => (404, "{}".into()),
        }
    })).await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: origin, session_cookie: COOKIE.into() });
    let model = ChatViewModel::new(App::new(Box::new(store.clone()), None));
    model.load("p".into(), "s".into()).await;
    (model, store, requests)
}
fn image(model: &ChatViewModel) -> String {
    let state = model.state();
    let ChatContent::User { attachments, .. } = &state.items[0].content else { panic!("missing attachment") };
    attachments[0].file_id.clone()
}

#[tokio::test]
async fn originals_are_preferred_without_contacting_a_workspace() {
    let (model, _, requests) = fixture(200, 500, "photo.png", "PNG!".into()).await;
    assert_eq!(model.document_bytes(image(&model)).await.unwrap(), b"PNG!");
    assert_eq!(*requests.lock().unwrap(), ["original"]);
}

#[tokio::test]
async fn deleted_expired_or_unsupported_originals_use_the_authenticated_workspace_copy() {
    for status in [404, 410] {
        let (model, _, requests) = fixture(status, 200, "my photo 1.png", "PNG!".into()).await;
        assert_eq!(model.document_bytes(image(&model)).await.unwrap(), b"PNG!");
        assert_eq!(*requests.lock().unwrap(), ["original", "workspace"]);
        assert!(model.document_bytes(format!("attachment:{UPLOAD}/not-referenced.png")).await.is_none());
        assert_eq!(requests.lock().unwrap().len(), 2, "Unreferenced paths must never be requested");
    }
}

#[tokio::test]
async fn authorization_and_server_errors_never_trigger_a_fallback() {
    for status in [401, 403, 429, 500] {
        let (model, store, requests) = fixture(status, 200, "photo.png", "{}".into()).await;
        assert!(model.document_bytes(image(&model)).await.is_none());
        assert_eq!(*requests.lock().unwrap(), ["original"]);
        assert_eq!(store.0.lock().unwrap().is_none(), status == 401);
    }
}

#[tokio::test]
async fn missing_or_denied_workspace_copies_stay_unavailable_without_more_fallbacks() {
    for status in [401, 403, 404, 502] {
        let (model, store, requests) = fixture(404, status, "photo.png", "{}".into()).await;
        assert!(model.document_bytes(image(&model)).await.is_none());
        assert_eq!(*requests.lock().unwrap(), ["original", "workspace"]);
        assert_eq!(store.0.lock().unwrap().is_none(), status == 401);
    }
}

#[tokio::test]
async fn workspace_previews_keep_the_existing_binary_size_limit() {
    let (model, _, requests) = fixture(404, 200, "photo.png", "x".repeat(20 * 1024 * 1024 + 1)).await;
    assert!(model.document_bytes(image(&model)).await.is_none());
    assert_eq!(*requests.lock().unwrap(), ["original", "workspace"]);
}

#[tokio::test]
async fn tool_metadata_cannot_turn_an_attachment_id_into_an_arbitrary_path() {
    let ids: Vec<String> = ["../secret.png", "..", ".", "", "nested/secret.png", "nested\\secret.png", "photo\n.png"]
        .into_iter()
        .map(|filename| format!("attachment:{UPLOAD}/{filename}"))
        .collect();
    let exposed = ids.clone();
    let origin = serve(Arc::new(move |request| {
        match request.path.as_str() {
        "/api/projects/p/sessions/s" => (200, json!({
            "session":{"id":"s","status":"active","startedAt":1},
            "messages": exposed.iter().enumerate().map(|(i, id)| json!({
                "id":format!("m{i}"),"role":"tool","createdAt":i,
                "toolMetadata":{"toolName":"display_from_library","rawOutput":{"fileId":id,"filename":"photo.png","mimeType":"image/png"}}
            })).collect::<Vec<_>>()
        }).to_string()),
        "/api/report-issue/config" => (200, "{}".into()),
        path if path.starts_with("/api/notifications?") => (200, json!({"notifications":[]}).to_string()),
        _ => panic!("Invalid references must not produce file requests: {}", request.path),
    }
    }))
    .await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: origin, session_cookie: COOKIE.into() });
    let model = ChatViewModel::new(App::new(Box::new(store), None));
    model.load("p".into(), "s".into()).await;
    assert_eq!(model.state().items.len(), ids.len());
    for id in ids {
        assert!(model.document_bytes(id).await.is_none());
    }
}
