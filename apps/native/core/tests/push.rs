//! The push token: held until sign-in, registered while signed in, removed on sign-out.

mod common;

use std::sync::{Arc, Mutex};

use common::{serve, MemoryStore, Request};
use sam_core::{App, AuthStatus, PushPlatform, PushToken};

const COOKIE: &str = "__Secure-better-auth.session_token=abc.sig";

#[tokio::test]
async fn token_registers_after_sign_in_and_unregisters_on_sign_out() {
    let calls: Arc<Mutex<Vec<String>>> = Arc::default();
    let log = calls.clone();
    let server = serve(Arc::new(move |r: &Request| {
        if r.path.starts_with("/api/notifications/") {
            assert_eq!(r.header("cookie").as_deref(), Some(COOKIE));
            log.lock().unwrap().push(format!("{} {}", r.method, String::from_utf8_lossy(&r.body)));
        }
        match (r.method.as_str(), r.path.as_str()) {
            ("POST", "/api/auth/device/code") => (
                200,
                r#"{"deviceCode":"dev","userCode":"C","verificationUri":"u","verificationUriComplete":"u","expiresIn":60,"interval":1}"#
                    .into(),
            ),
            ("POST", "/api/auth/device/token") => (200, format!(r#"{{"sessionCookie":"{COOKIE}"}}"#)),
            ("GET", "/api/auth/get-session") => (200, r#"{"session":{},"user":{"id":"u1","name":"Ada","email":"a@b.c"}}"#.into()),
            _ => (201, r#"{"success":true}"#.into()),
        }
    }))
    .await;
    let app = App::new(Box::new(MemoryStore::default()), None);

    // Signed out: the token is only remembered.
    app.set_push_token(PushToken { platform: PushPlatform::Apns, token: "ab12".into(), sandbox: true }).await;
    assert!(calls.lock().unwrap().is_empty());

    app.begin_sign_in(server).await.expect("device code");
    app.finish_sign_in().await;
    assert_eq!(app.state().status, AuthStatus::SignedIn);
    assert_eq!(*calls.lock().unwrap(), [r#"POST {"platform":"apns","token":"ab12","sandbox":true}"#]);

    app.sign_out().await;
    assert_eq!(calls.lock().unwrap()[1], r#"DELETE {"token":"ab12"}"#);
}
