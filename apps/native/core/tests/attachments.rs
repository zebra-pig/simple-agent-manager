//! Attaching files: presigned upload, then the task or follow-up carries them,
//! against a scripted stand-in for the SAM API and R2.

mod common;

use std::sync::{Arc, Mutex};

use common::{serve, MemoryStore, Request};
use sam_core::{App, AttachmentSource, AttachmentStatus, ChatViewModel, Credentials, ProjectViewModel, UserError};
use serde_json::{json, Value};

const COOKIE: &str = "session=abc";

/// Every request the app made: (method, path, cookie, content type, body).
type Log = Arc<Mutex<Vec<(String, String, Option<String>, Option<String>, Vec<u8>)>>>;

async fn api(log: Log) -> (Arc<App>, String) {
    let origin = Arc::new(Mutex::new(String::new()));
    let base = origin.clone();
    let server = serve(Arc::new(move |r: &Request| {
        log.lock().unwrap().push((r.method.clone(), r.path.clone(), r.header("cookie"), r.header("content-type"), r.body.clone()));
        let base = base.lock().unwrap().clone();
        match (r.method.as_str(), r.path.as_str()) {
            ("POST", "/api/projects/p1/tasks/request-upload") => {
                let n = log.lock().unwrap().iter().filter(|e| e.1.ends_with("request-upload")).count();
                (200, json!({"uploadId": format!("up{n}"), "uploadUrl": format!("{base}/r2/up{n}?sig=x"), "expiresIn": 900}).to_string())
            }
            ("PUT", p) if p.starts_with("/r2/") => (200, String::new()),
            ("POST", "/api/projects/p1/tasks/submit") => {
                (202, r#"{"taskId":"t1","sessionId":"s1","branchName":"b","status":"queued"}"#.into())
            }
            ("GET", "/api/projects/p1/sessions?limit=50") => (200, r#"{"sessions":[]}"#.into()),
            ("POST", "/api/projects/p1/sessions/s1/prompt") => (202, r#"{"accepted":true}"#.into()),
            ("GET", "/api/projects/p1/sessions/s1") => {
                (200, r#"{"session":{"id":"s1","status":"active","startedAt":1},"messages":[]}"#.into())
            }
            _ => (404, r#"{"error":"NOT_FOUND","message":"Not found"}"#.into()),
        }
    }))
    .await;
    *origin.lock().unwrap() = server.clone();
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server.clone(), session_cookie: COOKIE.into() });
    (App::new(Box::new(store), None), server)
}

struct Bytes(Option<Vec<u8>>);

impl AttachmentSource for Bytes {
    fn read(&self) -> Option<Vec<u8>> {
        self.0.clone()
    }
}

fn file(data: &[u8]) -> Box<dyn AttachmentSource> {
    Box::new(Bytes(Some(data.to_vec())))
}

fn json_body(body: &[u8]) -> Value {
    serde_json::from_slice(body).unwrap()
}

#[tokio::test]
async fn a_new_task_carries_its_files() {
    let log = Log::default();
    let (app, _) = api(log.clone()).await;
    let project = ProjectViewModel::new(app);
    project.load("p1".into()).await;

    project.add_attachment("Screen Shot 1.png".into(), "image/png".into(), 4, file(b"\x89PNG")).await;
    project.add_attachment("notes".into(), String::new(), 99, file(b"hello")).await; // size hint was off
    let attached = project.state().attachments;
    assert_eq!(attached.len(), 2);
    assert!(attached.iter().all(|a| a.status == AttachmentStatus::Ready), "{attached:?}");
    assert_eq!(attached[0].filename, "Screen_Shot_1.png");
    assert_eq!(attached[1].size, 5);

    let requests = log.lock().unwrap().clone();
    let presign = &requests.iter().find(|r| r.1.ends_with("request-upload")).unwrap();
    assert_eq!(json_body(&presign.4), json!({"filename": "Screen_Shot_1.png", "size": 4, "contentType": "image/png"}));
    assert_eq!(presign.2.as_deref(), Some(COOKIE));
    let puts: Vec<_> = requests.iter().filter(|r| r.0 == "PUT").collect();
    assert_eq!(puts.len(), 2);
    assert_eq!((puts[0].2.as_ref(), puts[0].3.as_deref(), puts[0].4.as_slice()), (None, Some("image/png"), &b"\x89PNG"[..]));
    assert_eq!(puts[1].3.as_deref(), Some("application/octet-stream"));

    // No text: the agent is asked to read the files.
    let task = project.submit_task("  ".into()).await.expect("submitted");
    assert_eq!(task.session_id, "s1");
    let submit = log.lock().unwrap().iter().find(|r| r.1.ends_with("/tasks/submit")).unwrap().4.clone();
    assert_eq!(
        json_body(&submit),
        json!({"message": "Please read the attached files.", "attachments": [
            {"uploadId": "up1", "filename": "Screen_Shot_1.png", "size": 4, "contentType": "image/png"},
            {"uploadId": "up2", "filename": "notes", "size": 5, "contentType": "application/octet-stream"},
        ]})
    );
    assert!(project.state().attachments.is_empty());
}

#[tokio::test]
async fn a_follow_up_waits_for_every_file() {
    let log = Log::default();
    let (app, _) = api(log.clone()).await;
    let chat = ChatViewModel::new(app);
    chat.load("p1".into(), "s1".into()).await;

    chat.add_attachment("gone.txt".into(), "text/plain".into(), 3, Box::new(Bytes(None))).await;
    chat.add_attachment("empty.txt".into(), "text/plain".into(), 0, file(b"")).await;
    let attached = chat.state().attachments;
    assert_eq!(attached[0].status, AttachmentStatus::Failed { error: UserError::FileUnreadable });
    assert_eq!(attached[1].status, AttachmentStatus::Failed { error: UserError::FileEmpty });

    // A failed file blocks sending until it is removed.
    assert!(!chat.send("look".into()).await);
    assert_eq!(chat.state().error, Some(UserError::AttachmentsNotReady));
    assert!(!log.lock().unwrap().iter().any(|r| r.1.ends_with("/prompt")));

    for a in attached {
        chat.remove_attachment(a.id);
    }
    chat.add_attachment("log.txt".into(), "text/plain".into(), 2, file(b"ok")).await;
    assert!(chat.send("Here is the log".into()).await);
    let prompt = log.lock().unwrap().iter().find(|r| r.1.ends_with("/prompt")).unwrap().4.clone();
    assert_eq!(
        json_body(&prompt),
        json!({"content": "Here is the log", "attachments": [
            {"uploadId": "up1", "filename": "log.txt", "size": 2, "contentType": "text/plain"},
        ]})
    );
    assert!(chat.state().attachments.is_empty());

    // Without files the body stays as before.
    assert!(chat.send("thanks".into()).await);
    let last = log.lock().unwrap().iter().rev().find(|r| r.1.ends_with("/prompt")).unwrap().4.clone();
    assert_eq!(json_body(&last), json!({"content": "thanks"}));
}

#[tokio::test]
async fn switching_session_drops_its_files() {
    let (app, _) = api(Log::default()).await;
    let chat = ChatViewModel::new(app);
    chat.load("p1".into(), "s1".into()).await;
    chat.add_attachment("a.txt".into(), "text/plain".into(), 1, file(b"a")).await;
    assert_eq!(chat.state().attachments.len(), 1);
    chat.load("p1".into(), "s2".into()).await;
    assert!(chat.state().attachments.is_empty());
}

struct PreviewBytes { preview: Vec<u8> }
impl AttachmentSource for PreviewBytes {
    fn read(&self) -> Option<Vec<u8>> { Some(b"original image".to_vec()) }
    fn thumbnail(&self) -> Option<Vec<u8>> { Some(self.preview.clone()) }
}

#[tokio::test]
async fn thumbnails_are_local_bounded_and_do_not_replace_uploads() {
    let log = Log::default();
    let (app, _) = api(log.clone()).await;
    let project = ProjectViewModel::new(app);
    project.load("p1".into()).await;
    project.add_attachment("photo.png".into(), "image/png".into(), 14,
        Box::new(PreviewBytes { preview: b"small preview".to_vec() })).await;
    assert_eq!(project.state().attachments[0].thumbnail.as_deref(), Some(b"small preview".as_slice()));
    let requests = log.lock().unwrap().clone();
    let put = requests.iter().find(|r| r.0 == "PUT").unwrap();
    assert_eq!(put.4, b"original image");
    assert!(!requests.iter().any(|r| r.4.windows(13).any(|s| s == b"small preview")));
    project.add_attachment("large.png".into(), "image/png".into(), 14,
        Box::new(PreviewBytes { preview: vec![0; 1024 * 1024 + 1] })).await;
    let state = project.state();
    assert_eq!(state.attachments[1].thumbnail, None);
    assert_eq!(state.attachments[1].status, AttachmentStatus::Ready);
}
