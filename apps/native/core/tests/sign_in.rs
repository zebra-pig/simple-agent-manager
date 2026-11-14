//! Device-flow sign-in, an authenticated read and session expiry against a
//! scripted stand-in for the SAM API.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use sam_core::{App, AuthStatus, CredentialStore, Credentials, ProjectListViewModel};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Clones share one slot, so the test can look at what the app saved.
#[derive(Default, Clone)]
struct MemoryStore(Arc<Mutex<Option<Credentials>>>);

impl CredentialStore for MemoryStore {
    fn load(&self) -> Option<Credentials> {
        self.0.lock().unwrap().clone()
    }
    fn save(&self, credentials: Credentials) {
        *self.0.lock().unwrap() = Some(credentials);
    }
    fn clear(&self) {
        *self.0.lock().unwrap() = None;
    }
}

const COOKIE: &str = "__Secure-better-auth.session_token=abc.sig";

/// Answers one request per connection: (status, JSON body).
fn route(method: &str, path: &str, headers: &str, polls: &AtomicUsize, valid: bool) -> (u16, String) {
    let authed = valid && headers.lines().any(|l| l.eq_ignore_ascii_case(&format!("cookie: {COOKIE}")));
    match (method, path) {
        ("POST", "/api/auth/device/code") => (
            200,
            r#"{"deviceCode":"dev","userCode":"ABCD-1234","verificationUri":"https://app.test/device",
                "verificationUriComplete":"https://app.test/device?code=ABCD-1234","expiresIn":60,"interval":1}"#
                .into(),
        ),
        ("POST", "/api/auth/device/token") => {
            if polls.fetch_add(1, Ordering::SeqCst) == 0 {
                (428, r#"{"error":"authorization_pending","message":"Authorization is still pending"}"#.into())
            } else {
                (200, format!(r#"{{"success":true,"user":{{"id":"u1"}},"sessionCookie":"{COOKIE}"}}"#))
            }
        }
        ("GET", "/api/auth/get-session") if authed => {
            (200, r#"{"session":{"id":"s"},"user":{"id":"u1","name":"Ada","email":"ada@example.com","image":null}}"#.into())
        }
        ("GET", "/api/auth/get-session") => (200, "null".into()),
        ("GET", "/api/projects") if authed => {
            (200, r#"{"projects":[{"id":"p1","name":"Rocket","repository":"o/rocket"}],"nextCursor":null}"#.into())
        }
        _ => (401, r#"{"error":"UNAUTHORIZED","message":"Authentication required"}"#.into()),
    }
}

async fn serve(valid: Arc<std::sync::atomic::AtomicBool>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let polls = Arc::new(AtomicUsize::new(0));
    tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let polls = polls.clone();
            let valid = valid.clone();
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                // Headers, then Content-Length bytes of body.
                let (head, body_len, head_end) = loop {
                    let n = socket.read(&mut chunk).await.unwrap();
                    if n == 0 {
                        return;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&buf[..i]).to_string();
                        let len = head
                            .lines()
                            .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse().unwrap()))
                            .unwrap_or(0usize);
                        break (head, len, i + 4);
                    }
                };
                while buf.len() < head_end + body_len {
                    let n = socket.read(&mut chunk).await.unwrap();
                    buf.extend_from_slice(&chunk[..n]);
                }
                let mut first = head.lines().next().unwrap().split(' ');
                let (method, path) = (first.next().unwrap(), first.next().unwrap());
                let (status, body) = route(method, path, &head, &polls, valid.load(Ordering::SeqCst));
                let res = format!(
                    "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket.write_all(res.as_bytes()).await.unwrap();
            });
        }
    });
    format!("http://localhost:{}", addr.port())
}

#[tokio::test]
async fn device_flow_then_authenticated_reads_then_expiry() {
    let valid = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let server = serve(valid.clone()).await;
    let store = MemoryStore::default();
    let app = App::new(Box::new(store.clone()), None);
    assert_eq!(app.state().status, AuthStatus::SignedOut);

    let url = app.begin_sign_in(server.clone()).await.expect("device code");
    assert_eq!(url, "https://app.test/device?code=ABCD-1234");
    let state = app.state();
    assert_eq!(state.status, AuthStatus::SigningIn);
    assert_eq!(state.sign_in.unwrap().user_code, "ABCD-1234");

    app.finish_sign_in().await; // one pending poll, then approved
    let state = app.state();
    assert_eq!(state.status, AuthStatus::SignedIn, "{:?}", state.error);
    assert_eq!(state.viewer.unwrap().name, "Ada");
    assert_eq!(store.load().unwrap(), Credentials { server_url: server.clone(), session_cookie: COOKIE.into() });

    let projects = ProjectListViewModel::new(app.clone());
    projects.load().await;
    assert_eq!(projects.state().projects[0].name, "Rocket");

    // A restart signs straight in from the store.
    assert_eq!(App::new(Box::new(store.clone()), None).state().status, AuthStatus::SignedIn);

    // The server forgets the session: the next read signs out and clears the store.
    valid.store(false, Ordering::SeqCst);
    projects.load().await;
    assert!(projects.state().error.is_some());
    assert_eq!(app.state().status, AuthStatus::SignedOut);
    assert!(store.load().is_none());
}

#[tokio::test]
async fn cancel_stops_the_poll() {
    let server = serve(Arc::new(std::sync::atomic::AtomicBool::new(true))).await;
    let app = App::new(Box::new(MemoryStore::default()), None);
    app.begin_sign_in(server).await.unwrap();
    let waiting = {
        let app = app.clone();
        tokio::spawn(async move { app.finish_sign_in().await })
    };
    app.cancel_sign_in();
    waiting.await.unwrap();
    assert_eq!(app.state().status, AuthStatus::SignedOut);
    assert!(app.state().sign_in.is_none());
}

#[test]
fn preset_server_is_used_until_signed_in() {
    let app = App::new(Box::new(MemoryStore::default()), Some("example.com".into()));
    assert_eq!(app.state().server_url, "https://api.example.com");
    let fallback = App::new(Box::new(MemoryStore::default()), Some("https://bad".into()));
    assert_eq!(fallback.state().server_url, "https://api.simple-agent-manager.org");
}
