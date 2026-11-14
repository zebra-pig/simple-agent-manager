//! The app-wide session: which server, the session cookie, device-flow sign-in,
//! the authenticated HTTP transport, and the root view model (signed in or not,
//! who). One `App` per process; the screen view models borrow it.
//!
//! Sign-in is SAM's device flow, the one `sam login` uses
//! (apps/api/src/routes/device-flow.ts): the app asks for a code, the user
//! approves it in the browser where they are signed in to SAM, and the app's
//! poll gets a session cookie back. Nothing on the server is app-specific.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

use crate::api::{GetSessionResponse, Viewer};
use crate::error::{CoreError, Result, UserError};
use crate::server::{self, DEFAULT_BASE_DOMAIN};

/// What the shell persists: Keychain (Apple) / Keystore-encrypted prefs (Android).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Credentials {
    /// API origin, e.g. `https://api.simple-agent-manager.org`.
    pub server_url: String,
    /// `name=value`, sent as the `Cookie` header.
    pub session_cookie: String,
}

/// The core never touches platform storage itself.
#[uniffi::export(callback_interface)]
pub trait CredentialStore: Send + Sync {
    fn load(&self) -> Option<Credentials>;
    fn save(&self, credentials: Credentials);
    fn clear(&self);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AuthStatus {
    SignedOut,
    /// A device code is out; waiting for the user to approve it in the browser.
    SigningIn,
    SignedIn,
}

/// The code the user should see in the browser before approving.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DeviceSignIn {
    pub user_code: String,
    /// The approval page with the code filled in.
    pub verification_url: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppState {
    pub status: AuthStatus,
    /// The server signed in to, or the one the sign-in screen suggests.
    pub server_url: String,
    /// Loaded right after sign-in (and on `refresh_viewer`).
    pub viewer: Option<Viewer>,
    pub sign_in: Option<DeviceSignIn>,
    pub error: Option<UserError>,
}

#[uniffi::export(callback_interface)]
pub trait AppObserver: Send + Sync {
    fn on_state_changed(&self, state: AppState);
}

#[derive(Clone)]
struct PendingSignIn {
    generation: u64,
    server_url: String,
    device_code: String,
    interval: Duration,
    deadline: tokio::time::Instant,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeviceCodeResponse {
    device_code: String,
    user_code: String,
    verification_uri_complete: String,
    expires_in: u64,
    interval: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LoginResponse {
    session_cookie: String,
}

/// `AppError` body (apps/api/src/middleware/error.ts).
#[derive(Deserialize, Default)]
struct ErrorBody {
    #[serde(default)]
    error: String,
    #[serde(default)]
    message: String,
}

#[derive(uniffi::Object)]
pub struct App {
    http: reqwest::Client,
    store: Box<dyn CredentialStore>,
    credentials: Mutex<Option<Credentials>>,
    /// Bumped by every begin/cancel, so a stale poll loop stops.
    sign_in_generation: AtomicU64,
    pending: Mutex<Option<PendingSignIn>>,
    state: Mutex<AppState>,
    observer: Mutex<Option<Arc<dyn AppObserver>>>,
}

#[uniffi::export(async_runtime = "tokio")]
impl App {
    /// `base_domain` is the build's preset deployment (its `BASE_DOMAIN`, e.g. from a
    /// white-label build); `None` or an invalid value falls back to the hosted SAM.
    #[uniffi::constructor]
    pub fn new(store: Box<dyn CredentialStore>, base_domain: Option<String>) -> Arc<Self> {
        let credentials = store.load();
        let status = if credentials.is_some() { AuthStatus::SignedIn } else { AuthStatus::SignedOut };
        let server_url = credentials.as_ref().map_or_else(
            || {
                base_domain
                    .and_then(|d| server::api_origin(&d).ok())
                    .unwrap_or_else(|| server::api_origin(DEFAULT_BASE_DOMAIN).expect("valid default"))
            },
            |c| c.server_url.clone(),
        );
        Arc::new(App {
            http: reqwest::Client::builder()
                .user_agent(concat!("sam-native/", env!("CARGO_PKG_VERSION")))
                .timeout(Duration::from_secs(30))
                .build()
                .expect("HTTP client"),
            store,
            credentials: Mutex::new(credentials),
            sign_in_generation: AtomicU64::new(0),
            pending: Mutex::new(None),
            state: Mutex::new(AppState { status, server_url, viewer: None, sign_in: None, error: None }),
            observer: Mutex::new(None),
        })
    }

    pub fn set_observer(&self, observer: Box<dyn AppObserver>) {
        *self.observer.lock().unwrap() = Some(Arc::from(observer));
    }

    pub fn clear_observer(&self) {
        *self.observer.lock().unwrap() = None;
    }

    pub fn state(&self) -> AppState {
        self.state.lock().unwrap().clone()
    }

    /// Intent: start signing in to `server_url`. Returns the approval page the
    /// shell opens in the browser, then it calls `finish_sign_in`. `None` when
    /// the code could not be created (the reason is in `state.error`).
    pub async fn begin_sign_in(&self, server_url: String) -> Option<String> {
        let generation = self.sign_in_generation.fetch_add(1, Ordering::SeqCst) + 1;
        let result = async {
            let server_url = server::normalize(&server_url)?;
            let res = self.http.post(format!("{server_url}/api/auth/device/code")).send().await?;
            let code: DeviceCodeResponse = read_json(res).await?;
            Ok::<_, CoreError>((server_url, code))
        }
        .await;
        if self.sign_in_generation.load(Ordering::SeqCst) != generation {
            return None; // cancelled meanwhile
        }
        match result {
            Ok((server_url, code)) => {
                *self.pending.lock().unwrap() = Some(PendingSignIn {
                    generation,
                    server_url: server_url.clone(),
                    device_code: code.device_code,
                    interval: Duration::from_secs(code.interval.max(1)),
                    deadline: tokio::time::Instant::now() + Duration::from_secs(code.expires_in),
                });
                let url = code.verification_uri_complete.clone();
                self.update(|s| {
                    s.status = AuthStatus::SigningIn;
                    s.server_url = server_url;
                    s.sign_in = Some(DeviceSignIn { user_code: code.user_code, verification_url: code.verification_uri_complete });
                    s.error = None;
                });
                Some(url)
            }
            Err(e) => {
                self.update(|s| {
                    s.status = AuthStatus::SignedOut;
                    s.sign_in = None;
                    s.error = Some(UserError::from(&e));
                });
                None
            }
        }
    }

    /// Intent: wait for the user to approve the code. Polls until approved,
    /// expired, failed, or `cancel_sign_in`.
    pub async fn finish_sign_in(&self) {
        let Some(mut pending) = self.pending.lock().unwrap().clone() else { return };
        let current = || self.sign_in_generation.load(Ordering::SeqCst) == pending.generation;
        let result = loop {
            tokio::time::sleep(pending.interval).await;
            if !current() {
                return;
            }
            if tokio::time::Instant::now() >= pending.deadline {
                break Err(CoreError::SignInExpired);
            }
            match self.poll_device_token(&pending).await {
                Ok(Some(cookie)) => break Ok(cookie),
                Ok(None) => {}
                Err(PollError::SlowDown) => pending.interval += Duration::from_secs(5),
                Err(PollError::Failed(e)) => break Err(e),
            }
        };
        if !current() {
            return;
        }
        self.pending.lock().unwrap().take();
        match result {
            Ok(session_cookie) => {
                let credentials = Credentials { server_url: pending.server_url, session_cookie };
                self.store.save(credentials.clone());
                *self.credentials.lock().unwrap() = Some(credentials);
                self.update(|s| {
                    s.status = AuthStatus::SignedIn;
                    s.sign_in = None;
                    s.error = None;
                });
                self.refresh_viewer().await;
            }
            Err(e) => self.update(|s| {
                s.status = AuthStatus::SignedOut;
                s.sign_in = None;
                s.error = Some(UserError::from(&e));
            }),
        }
    }

    /// Intent: the user gave up on this sign-in.
    pub fn cancel_sign_in(&self) {
        self.sign_in_generation.fetch_add(1, Ordering::SeqCst);
        self.pending.lock().unwrap().take();
        self.update(|s| {
            if s.status == AuthStatus::SigningIn {
                s.status = AuthStatus::SignedOut;
            }
            s.sign_in = None;
        });
    }

    /// Intent: (re)load who is signed in. Call on launch when already signed in.
    pub async fn refresh_viewer(&self) {
        match self.get::<Option<GetSessionResponse>>("/api/auth/get-session").await {
            Ok(Some(session)) => self.update(|s| {
                s.viewer = Some(session.user);
                s.error = None;
            }),
            // better-auth answers `null` for a cookie it no longer knows.
            Ok(None) => self.expire(),
            Err(CoreError::Unauthenticated) => {} // already signed out
            Err(e) => self.update(|s| s.error = Some(UserError::from(&e))),
        }
    }

    pub async fn sign_out(&self) {
        let credentials = self.credentials.lock().unwrap().take();
        self.store.clear();
        self.update(|s| {
            s.status = AuthStatus::SignedOut;
            s.viewer = None;
            s.error = None;
        });
        if let Some(c) = credentials {
            // Best effort: signed out locally either way.
            let _ = self
                .http
                .post(format!("{}/api/auth/sign-out", c.server_url))
                .header(reqwest::header::COOKIE, &c.session_cookie)
                .json(&serde_json::json!({}))
                .send()
                .await;
        }
    }
}

enum PollError {
    SlowDown,
    Failed(CoreError),
}

impl App {
    fn update(&self, f: impl FnOnce(&mut AppState)) {
        let snapshot = {
            let mut s = self.state.lock().unwrap();
            f(&mut s);
            s.clone()
        };
        let observer = self.observer.lock().unwrap().clone();
        if let Some(o) = observer {
            o.on_state_changed(snapshot);
        }
    }

    /// `Ok(None)` while the code is still pending.
    async fn poll_device_token(&self, pending: &PendingSignIn) -> std::result::Result<Option<String>, PollError> {
        let res = self
            .http
            .post(format!("{}/api/auth/device/token", pending.server_url))
            .json(&serde_json::json!({ "deviceCode": pending.device_code }))
            .send()
            .await
            .map_err(|e| PollError::Failed(e.into()))?;
        match res.status().as_u16() {
            200 => {
                let login: LoginResponse = res.json().await.map_err(|e| PollError::Failed(e.into()))?;
                if login.session_cookie.is_empty() {
                    return Err(PollError::Failed(CoreError::Unexpected("device token response without a session".into())));
                }
                Ok(Some(login.session_cookie))
            }
            428 => Ok(None), // authorization_pending
            429 => Err(PollError::SlowDown),
            410 => Err(PollError::Failed(CoreError::SignInExpired)),
            _ => Err(PollError::Failed(error_from(res).await)),
        }
    }

    /// Session over: drop the cookie, tell the shell.
    fn expire(&self) {
        self.credentials.lock().unwrap().take();
        self.store.clear();
        self.update(|s| {
            s.status = AuthStatus::SignedOut;
            s.viewer = None;
            s.error = Some(UserError::SessionEnded);
        });
    }

    fn credentials(&self) -> Result<Credentials> {
        self.credentials.lock().unwrap().clone().ok_or(CoreError::Unauthenticated)
    }

    async fn send<T: DeserializeOwned>(&self, req: impl FnOnce(&reqwest::Client, &str) -> reqwest::RequestBuilder) -> Result<T> {
        let c = self.credentials()?;
        let res = req(&self.http, &c.server_url)
            .header(reqwest::header::COOKIE, &c.session_cookie)
            .header(reqwest::header::ACCEPT, "application/json")
            .send()
            .await?;
        if res.status() == 401 {
            // Only if nobody signed in again while this request was in flight.
            if self.credentials.lock().unwrap().as_ref() == Some(&c) {
                self.expire();
            }
            return Err(CoreError::Unauthenticated);
        }
        read_json(res).await
    }

    /// GET `path` (from `/api/...`) as the signed-in user.
    pub(crate) async fn get<T: DeserializeOwned>(&self, path: &str) -> Result<T> {
        self.send(|http, base| http.get(format!("{base}{path}"))).await
    }

    /// POST JSON to `path` as the signed-in user.
    pub(crate) async fn post<T: DeserializeOwned, B: Serialize>(&self, path: &str, body: &B) -> Result<T> {
        self.send(|http, base| http.post(format!("{base}{path}")).json(body)).await
    }
}

async fn read_json<T: DeserializeOwned>(res: reqwest::Response) -> Result<T> {
    if !res.status().is_success() {
        return Err(error_from(res).await);
    }
    Ok(res.json().await?)
}

async fn error_from(res: reqwest::Response) -> CoreError {
    let status = res.status();
    let body: ErrorBody = res.json().await.unwrap_or_default();
    match (body.message.is_empty(), body.error.is_empty()) {
        (false, _) => CoreError::Server(body.message),
        (true, false) => CoreError::Unexpected(format!("HTTP {status} ({})", body.error)),
        (true, true) => CoreError::Unexpected(format!("HTTP {status}")),
    }
}

/// Path segment escaping for ids in URLs.
pub(crate) fn seg(id: &str) -> String {
    url::form_urlencoded::byte_serialize(id.as_bytes()).collect()
}
