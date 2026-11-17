//! A chat started with files shows them right away. The server stores the first
//! message without its files (or not at all) until the agent starts and echoes
//! its prompt, which can take minutes while a workspace boots.
mod common;

use std::sync::{Arc, Mutex};

use common::{serve, MemoryStore, Request};
use sam_core::{App, AttachmentSource, ChatContent, ChatState, ChatViewModel, Credentials, ProjectViewModel};
use serde_json::json;

struct Png;

impl AttachmentSource for Png {
    fn read(&self) -> Option<Vec<u8>> {
        Some(b"\x89PNG".to_vec())
    }
}

/// The server's stored first message(s) of session s1, swapped as the agent starts.
type Messages = Arc<Mutex<serde_json::Value>>;

const SCREENSHOT: &str = "attachment:01M7GE2BN1VC90CZ76HN0FFKCQ/screenshot.png";

async fn started(message: &str, messages: Messages) -> (Arc<App>, Arc<ChatViewModel>) {
    let origin = Arc::new(Mutex::new(String::new()));
    let base = origin.clone();
    let server = serve(Arc::new(move |r: &Request| {
        let base = base.lock().unwrap().clone();
        match (r.method.as_str(), r.path.as_str()) {
            ("POST", "/api/projects/p1/tasks/request-upload") => (
                200,
                json!({"uploadId": "01M7GE2BN1VC90CZ76HN0FFKCQ", "uploadUrl": format!("{base}/r2/up?sig=x"), "expiresIn": 900}).to_string(),
            ),
            ("PUT", p) if p.starts_with("/r2/") => (200, String::new()),
            ("POST", "/api/projects/p1/tasks/submit") => {
                (202, r#"{"taskId":"t1","sessionId":"s1","branchName":"b","status":"queued"}"#.into())
            }
            ("GET", "/api/projects/p1/sessions?limit=50") => (200, r#"{"sessions":[]}"#.into()),
            ("GET", "/api/projects/p1/sessions/s1") => (
                200,
                json!({"session": {"id": "s1", "status": "active", "startedAt": 1}, "messages": messages.lock().unwrap().clone()})
                    .to_string(),
            ),
            _ => (404, r#"{"error":"NOT_FOUND","message":"Not found"}"#.into()),
        }
    }))
    .await;
    *origin.lock().unwrap() = server.clone();
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let app = App::new(Box::new(store), None);
    let project = ProjectViewModel::new(app.clone());
    project.load("p1".into()).await;
    project.add_attachment("screenshot.png".into(), "image/png".into(), 4, Box::new(Png)).await;
    let task = project.submit_task(message.into()).await.expect("submitted");
    project.finish_submission(task.session_id.clone());
    let chat = ChatViewModel::new(app.clone());
    chat.load("p1".into(), task.session_id).await;
    (app, chat)
}

/// Every user message the chat shows, from the server or on its way: (text, file ids).
fn shown(state: &ChatState) -> Vec<(String, Vec<String>)> {
    let ids = |docs: &[sam_core::ChatDocument]| docs.iter().map(|d| d.file_id.clone()).collect::<Vec<_>>();
    state
        .items
        .iter()
        .filter_map(|i| match &i.content {
            ChatContent::User { text, attachments } => Some((text.clone(), ids(attachments))),
            _ => None,
        })
        .chain(state.outbox.iter().map(|m| (m.text.clone(), ids(&m.attachments))))
        .collect()
}

fn envelope(text: &str) -> String {
    format!(
        "{text}\n\n## Attached Files\n\nThe following files have been uploaded to the workspace:\n\
         - `/workspaces/.private/01M7GE2BN1VC90CZ76HN0FFKCQ/screenshot.png` (4 bytes, image/png)\n\n\
         These are absolute paths inside your workspace container, outside the repository. Open the exact paths listed above to read the attachments; do not look for them relative to the repository.\n"
    )
}

#[tokio::test]
async fn the_screenshot_shows_on_the_plain_first_message_until_the_server_has_it() {
    let messages: Messages = Arc::new(Mutex::new(json!([{"id": "m1", "role": "user", "content": "Look at this", "createdAt": 1}])));
    let (app, chat) = started("Look at this", messages.clone()).await;
    // One message, carrying the screenshot, not a second pending copy of it.
    assert_eq!(shown(&chat.state()), vec![("Look at this".to_owned(), vec![SCREENSHOT.to_owned()])]);
    assert!(chat.state().outbox.is_empty(), "{:?}", chat.state().outbox);

    // Polling keeps it there while the agent is still starting.
    chat.refresh().await;
    assert_eq!(shown(&chat.state()), vec![("Look at this".to_owned(), vec![SCREENSHOT.to_owned()])]);

    // Leaving and reopening the chat still shows it.
    let reopened = ChatViewModel::new(app.clone());
    reopened.load("p1".into(), "s1".into()).await;
    assert_eq!(shown(&reopened.state()), vec![("Look at this".to_owned(), vec![SCREENSHOT.to_owned()])]);

    // Once the server stores the files itself, they come from there only.
    *messages.lock().unwrap() = json!([{"id": "m1", "role": "user", "content": envelope("Look at this"), "createdAt": 1}]);
    chat.refresh().await;
    assert_eq!(shown(&chat.state()), vec![("Look at this".to_owned(), vec![SCREENSHOT.to_owned()])]);
}

#[tokio::test]
async fn the_screenshot_is_pending_before_the_server_has_the_first_message() {
    let messages: Messages = Arc::new(Mutex::new(json!([])));
    // No typed text: the files are the message.
    let (_app, chat) = started("", messages.clone()).await;
    let state = chat.state();
    assert_eq!(shown(&state), vec![(String::new(), vec![SCREENSHOT.to_owned()])]);
    assert!(state.outbox[0].accepted, "it was submitted; it is on its way, not unsent");

    // The agent's echo carries the files: the pending copy leaves, nothing doubles.
    *messages.lock().unwrap() =
        json!([{"id": "e1", "role": "user", "content": envelope("Please read the attached files."), "createdAt": 2}]);
    chat.refresh().await;
    assert_eq!(shown(&chat.state()), vec![(String::new(), vec![SCREENSHOT.to_owned()])]);
    assert!(chat.state().outbox.is_empty());
}

#[tokio::test]
async fn a_different_first_message_is_left_alone() {
    let messages: Messages = Arc::new(Mutex::new(json!([{"id": "m1", "role": "user", "content": "Something else", "createdAt": 1}])));
    let (_app, chat) = started("Look at this", messages).await;
    assert_eq!(shown(&chat.state()), vec![("Something else".to_owned(), vec![]), ("Look at this".to_owned(), vec![SCREENSHOT.to_owned()])]);
}
