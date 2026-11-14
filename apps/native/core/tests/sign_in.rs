//! Device-flow sign-in, an authenticated read and session expiry against a
//! scripted stand-in for the SAM API.

mod common;

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;

use common::{serve, MemoryStore, Request};
use sam_core::{App, AuthStatus, CredentialStore, Credentials, ProjectListViewModel};

const COOKIE: &str = "__Secure-better-auth.session_token=abc.sig";

/// The device flow and two authenticated reads; `valid` false forgets the session.
async fn api(valid: Arc<AtomicBool>) -> String {
    let polls = Arc::new(AtomicUsize::new(0));
    serve(Arc::new(move |r: &Request| route(r, &polls, valid.load(Ordering::SeqCst)))).await
}

fn route(r: &Request, polls: &AtomicUsize, valid: bool) -> (u16, String) {
    let authed = valid && r.header("cookie").as_deref() == Some(COOKIE);
    match (r.method.as_str(), r.path.as_str()) {
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

#[tokio::test]
async fn device_flow_then_authenticated_reads_then_expiry() {
    let valid = Arc::new(AtomicBool::new(true));
    let server = api(valid.clone()).await;
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
    let server = api(Arc::new(AtomicBool::new(true))).await;
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
