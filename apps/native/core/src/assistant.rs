//! The private, account-wide SAM conversation, using the same projected API as web.
use crate::session::seg;
use crate::{App, UserError};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, Default, PartialEq, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct AssistantAction {
    pub id: String,
    pub operation: String,
    pub input_json: String,
    pub state: String,
    pub result_json: Option<String>,
    pub available: Option<bool>,
}
#[derive(Debug, Clone, Default, PartialEq, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct AssistantActivity {
    pub id: String,
    pub operation: String,
    pub state: String,
}
#[derive(Debug, Clone, Default, PartialEq, Deserialize, uniffi::Record)]
#[serde(default, rename_all = "camelCase")]
pub struct AssistantLive {
    pub phase: String,
    pub elapsed_ms: u64,
    pub text: String,
    pub thinking: Option<String>,
    pub activity: Vec<AssistantActivity>,
}
#[derive(Debug, Clone, Default, PartialEq, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct AssistantTurn {
    pub id: String,
    pub request_key: String,
    pub message: String,
    pub state: String,
    pub response: Option<String>,
    pub error: Option<String>,
    pub actions: Vec<AssistantAction>,
    pub live: Option<AssistantLive>,
}
impl AssistantTurn {
    fn active(&self) -> bool {
        matches!(self.state.as_str(), "accepted" | "running")
    }
}
#[derive(Debug, Clone, Default, PartialEq, Deserialize, uniffi::Record)]
#[serde(default, rename_all = "camelCase")]
pub struct AssistantUpdates {
    pub unread: u32,
}
#[derive(Debug, Clone, Default, PartialEq, Deserialize, uniffi::Record)]
#[serde(default, rename_all = "camelCase")]
pub struct AssistantWork {
    pub action_id: String,
    pub project_id: String,
    pub task_id: String,
    pub session_id: Option<String>,
    pub task_title: Option<String>,
    pub project_name: Option<String>,
    pub status: String,
    pub attention: bool,
    pub error: Option<String>,
    pub updates: Option<AssistantUpdates>,
}
#[derive(Debug, Clone, Default, PartialEq, Deserialize, uniffi::Record)]
#[serde(default)]
pub struct AssistantEarlierMessage {
    pub id: String,
    pub role: String,
    pub content: String,
}
#[derive(Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct History {
    conversation_id: Option<String>,
    legacy_history_available: bool,
    turns: Vec<AssistantTurn>,
    next_cursor: Option<String>,
    work: Vec<AssistantWork>,
}
#[derive(Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct EarlierHistory {
    messages: Vec<AssistantEarlierMessage>,
    next_cursor: Option<u64>,
}
#[derive(Deserialize)]
struct Settings {
    enabled: bool,
    available: bool,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct AssistantPending {
    pub request_key: String,
    pub message: String,
}
/// Shell-backed durable storage. The scope is the server origin and private conversation ID.
/// Persist before POST, so retries after a lost receipt or app restart reuse the same key.
#[uniffi::export(callback_interface)]
pub trait AssistantStore: Send + Sync {
    fn load(&self, scope: String) -> Option<AssistantPending>;
    fn save(&self, scope: String, pending: AssistantPending) -> bool;
    fn clear(&self, scope: String);
}
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct AssistantState {
    pub enabled: bool,
    pub loaded: bool,
    pub loading: bool,
    pub busy: bool,
    pub turns: Vec<AssistantTurn>,
    pub work: Vec<AssistantWork>,
    pub next_cursor: Option<String>,
    pub conversation_id: Option<String>,
    pub legacy_history_available: bool,
    pub earlier: Vec<AssistantEarlierMessage>,
    pub earlier_cursor: Option<u64>,
    pub earlier_loaded: bool,
    pub pending: Option<AssistantPending>,
    pub error: Option<UserError>,
}
#[uniffi::export(callback_interface)]
pub trait AssistantObserver: Send + Sync {
    fn on_state_changed(&self, state: AssistantState);
}
#[derive(uniffi::Object)]
pub struct AssistantViewModel {
    app: Arc<App>,
    credentials: Option<crate::Credentials>,
    store: Box<dyn AssistantStore>,
    inner: Mutex<(AssistantState, Option<Arc<dyn AssistantObserver>>)>,
    // Serialize reads and writes; polling cannot overwrite a mutation with an older snapshot.
    gate: tokio::sync::Mutex<()>,
}
#[uniffi::export(async_runtime = "tokio")]
impl AssistantViewModel {
    #[uniffi::constructor]
    pub fn new(app: Arc<App>, store: Box<dyn AssistantStore>) -> Arc<Self> {
        Arc::new(Self {
            credentials: app.credentials().ok(),
            app,
            store,
            inner: Mutex::new((AssistantState::default(), None)),
            gate: tokio::sync::Mutex::new(()),
        })
    }
    pub fn state(&self) -> AssistantState {
        if self.app.credentials().ok() != self.credentials || self.credentials.is_none() {
            return AssistantState::default();
        }
        self.inner.lock().unwrap().0.clone()
    }
    pub fn set_observer(&self, observer: Box<dyn AssistantObserver>) {
        self.inner.lock().unwrap().1 = Some(Arc::from(observer));
    }
    pub fn clear_observer(&self) {
        self.inner.lock().unwrap().1 = None;
    }
    pub async fn refresh(&self) {
        let _guard = self.gate.lock().await;
        self.update(|s| s.loading = true);
        let result = self.refresh_inner().await;
        self.finish(result);
    }
    pub async fn load_older(&self) {
        let _guard = self.gate.lock().await;
        let Some(cursor) = self.state().next_cursor else { return };
        self.update(|s| s.loading = true);
        let result = async {
            let page: History = self.get(&format!("/api/sam/turns?before={}", seg(&cursor))).await?;
            self.update(|s| {
                let mut turns = page.turns;
                turns.retain(|t| !s.turns.iter().any(|old| old.id == t.id));
                turns.append(&mut s.turns);
                s.turns = turns;
                s.next_cursor = page.next_cursor;
            });
            Ok(())
        }
        .await;
        self.finish(result);
    }
    pub async fn load_earlier(&self) {
        let _guard = self.gate.lock().await;
        let state = self.state();
        let Some(id) = state.conversation_id else { return };
        if state.earlier_loaded && state.earlier_cursor.is_none() {
            return;
        }
        self.update(|s| s.loading = true);
        let result = async {
            let suffix = state.earlier_cursor.map(|c| format!("?before={c}")).unwrap_or_default();
            let page: EarlierHistory = self.get(&format!("/api/sam/conversations/{}/messages{suffix}", seg(&id))).await?;
            self.update(|s| {
                let mut messages = page.messages;
                messages.retain(|m| {
                    !m.id.starts_with("operator:")
                        && matches!(m.role.as_str(), "user" | "assistant")
                        && !s.earlier.iter().any(|old| old.id == m.id)
                });
                messages.append(&mut s.earlier);
                s.earlier = messages;
                s.earlier_cursor = page.next_cursor;
                s.earlier_loaded = true;
            });
            Ok(())
        }
        .await;
        self.finish(result);
    }
    /// The shell supplies a fresh UUID for a new message. An uncertain retry always uses the stored submission.
    pub async fn send(&self, message: String, request_key: String) {
        let _guard = self.gate.lock().await;
        let state = self.state();
        if !state.enabled || !state.loaded || state.turns.iter().any(AssistantTurn::active) {
            return;
        }
        let Some(scope) = self.scope() else { return };
        let pending = state.pending.unwrap_or(AssistantPending { message, request_key });
        if pending.message.trim().is_empty() || pending.request_key.is_empty() {
            return;
        }
        if !self.store.save(scope.clone(), pending.clone()) {
            self.finish(Err(crate::error::CoreError::Unexpected("Could not persist the retry receipt".into())));
            return;
        }
        self.update(|s| {
            s.busy = true;
            s.pending = Some(pending.clone());
            s.error = None;
        });
        let result = async {
            let receipt: Value =
                self.post("/api/sam/turns", &json!({"requestKey": pending.request_key, "message": pending.message})).await?;
            self.store.clear(scope);
            self.update(|s| {
                s.pending = None;
                if let Some(turn) = receipt.get("turn").and_then(|v| serde_json::from_value::<AssistantTurn>(v.clone()).ok()) {
                    if !s.turns.iter().any(|t| t.id == turn.id) {
                        s.turns.push(turn);
                    }
                }
            });
            self.refresh_inner().await
        }
        .await;
        self.finish(result);
    }
    pub async fn stop(&self) {
        let _guard = self.gate.lock().await;
        let Some(turn) = self.state().turns.into_iter().find(AssistantTurn::active) else { return };
        self.mutate(format!("/api/sam/turns/{}/cancel", seg(&turn.id)), json!({})).await;
    }
    pub async fn confirm(&self, action_id: String, approved: bool) {
        let _guard = self.gate.lock().await;
        let exists = self
            .state()
            .turns
            .iter()
            .flat_map(|t| &t.actions)
            .any(|a| a.id == action_id && a.state == "approval_required" && a.available != Some(false));
        if exists {
            self.mutate(format!("/api/sam/actions/{}/confirm", seg(&action_id)), json!({"approved": approved})).await;
        }
    }
    pub async fn reconcile(&self, action_id: String) {
        let _guard = self.gate.lock().await;
        let exists = self
            .state()
            .turns
            .iter()
            .flat_map(|t| &t.actions)
            .any(|a| a.id == action_id && a.operation == "sam_chat_start" && a.state == "uncertain" && a.available != Some(false));
        if exists {
            self.mutate(format!("/api/sam/actions/{}/reconcile", seg(&action_id)), json!({})).await;
        }
    }
    /// Voice entry fills the draft for review; it never sends a turn automatically.
    pub async fn transcribe(&self, audio: Vec<u8>) -> Option<String> {
        let _guard = self.gate.lock().await;
        if audio.is_empty() || audio.len() > 10_485_760 || !self.state().enabled {
            return None;
        }
        self.update(|s| {
            s.busy = true;
            s.error = None;
        });
        #[derive(Deserialize)]
        struct Transcript {
            text: String,
        }
        let result = async {
            let credentials = self.credentials.clone().ok_or(crate::error::CoreError::Unauthenticated)?;
            let part = reqwest::multipart::Part::bytes(audio)
                .file_name("voice.m4a")
                .mime_str("audio/mp4")
                .map_err(|e| crate::error::CoreError::Unexpected(e.to_string()))?;
            let form = reqwest::multipart::Form::new().part("audio", part);
            self.app.send_scoped::<Transcript>(credentials, |http, base| http.post(format!("{base}/api/transcribe")).multipart(form)).await
        }
        .await;
        match result {
            Ok(transcript) => {
                self.finish(Ok(()));
                Some(transcript.text)
            }
            Err(error) => {
                self.finish(Err(error));
                None
            }
        }
    }
    pub async fn mark_seen(&self, action_id: String) {
        let _guard = self.gate.lock().await;
        self.mutate(format!("/api/sam/updates/{}/seen", seg(&action_id)), json!({})).await;
    }
}
impl AssistantViewModel {
    async fn get<T: serde::de::DeserializeOwned>(&self, path: &str) -> crate::error::Result<T> {
        let credentials = self.credentials.clone().ok_or(crate::error::CoreError::Unauthenticated)?;
        self.app.send_scoped(credentials, |http, base| http.get(format!("{base}{path}"))).await
    }
    async fn post<T: serde::de::DeserializeOwned, B: Serialize>(&self, path: &str, body: &B) -> crate::error::Result<T> {
        let credentials = self.credentials.clone().ok_or(crate::error::CoreError::Unauthenticated)?;
        self.app.send_scoped(credentials, |http, base| http.post(format!("{base}{path}")).json(body)).await
    }
    fn update(&self, f: impl FnOnce(&mut AssistantState)) {
        let (state, observer) = {
            let mut inner = self.inner.lock().unwrap();
            if self.app.credentials().ok() == self.credentials && self.credentials.is_some() {
                f(&mut inner.0);
            } else {
                inner.0 = AssistantState::default();
            }
            (inner.0.clone(), inner.1.clone())
        };
        if let Some(observer) = observer {
            observer.on_state_changed(state);
        }
    }
    fn scope(&self) -> Option<String> {
        self.state()
            .conversation_id
            .map(|id| format!("{}:{id}", self.credentials.as_ref().map(|c| c.server_url.as_str()).unwrap_or_default()))
    }
    fn finish(&self, result: crate::error::Result<()>) {
        self.update(|s| {
            s.loading = false;
            s.busy = false;
            s.error = result.err().as_ref().map(UserError::from);
        });
    }
    async fn refresh_inner(&self) -> crate::error::Result<()> {
        let settings: Settings = match self.get("/api/sam/settings").await {
            Ok(settings) => settings,
            Err(error) => {
                self.update(|s| s.enabled = false);
                return Err(error);
            }
        };
        if !settings.enabled || !settings.available {
            self.update(|s| *s = AssistantState::default());
            return Ok(());
        }
        self.update(|s| s.enabled = true);
        let history: History = self.get("/api/sam/turns").await?;
        self.update(|s| {
            // Refresh the newest page without dropping previously loaded history.
            if let Some(first) = history.turns.first().and_then(|t| s.turns.iter().position(|old| old.id == t.id)) {
                s.turns.truncate(first);
                s.turns.extend(history.turns);
            } else {
                s.turns = history.turns;
            }
            if !s.loaded {
                s.next_cursor = history.next_cursor;
            }
            s.work = history.work;
            s.conversation_id = history.conversation_id;
            s.legacy_history_available = history.legacy_history_available;
            s.loaded = true;
        });
        if let Some(scope) = self.scope() {
            let pending = self.state().pending.or_else(|| self.store.load(scope.clone()));
            if let Some(pending) = pending {
                if self.state().turns.iter().any(|t| t.request_key == pending.request_key) {
                    self.store.clear(scope);
                    self.update(|s| s.pending = None);
                } else {
                    self.update(|s| s.pending = Some(pending));
                }
            }
        }
        Ok(())
    }
    async fn mutate(&self, path: String, body: Value) {
        self.update(|s| {
            s.busy = true;
            s.error = None;
        });
        let result = self.post::<Value, _>(&path, &body).await.map(|_| ());
        let refresh = self.refresh_inner().await;
        self.finish(result.and(refresh));
    }
}

/// Only web-safe destinations from projected receipts; shell routes project chats natively.
#[uniffi::export]
pub fn assistant_action_link(action: AssistantAction) -> Option<String> {
    if action.available == Some(false) {
        return None;
    }
    let result: Value = serde_json::from_str(action.result_json.as_deref().unwrap_or("null")).unwrap_or(Value::Null);
    if let Some(link) = result.get("link").and_then(Value::as_str) {
        if (link.starts_with('/') && !link.starts_with("//")) || url::Url::parse(link).is_ok_and(|u| u.scheme() == "https") {
            return Some(link.into());
        }
    }
    let input: Value = serde_json::from_str(&action.input_json).ok()?;
    let project = seg(input.get("projectId")?.as_str()?);
    for (key, path) in [("sessionId", "chat"), ("taskId", "tasks"), ("ideaId", "ideas")] {
        if let Some(id) = input.get(key).and_then(Value::as_str) {
            return Some(format!("/projects/{project}/{path}/{}", seg(id)));
        }
    }
    Some(format!("/projects/{project}"))
}

/// Render projected Markdown for Android's native selectable text view. Raw HTML
/// is text, and only web links are clickable; no embedded scripts or remote images.
#[uniffi::export]
pub fn assistant_markdown_html(markdown: String) -> String {
    use pulldown_cmark::{html, Event, Options, Parser, Tag, TagEnd};
    let mut output = String::new();
    let parser = Parser::new_ext(&markdown, Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TABLES).filter_map(|event| match event {
        Event::Html(text) | Event::InlineHtml(text) => Some(Event::Text(text)),
        Event::Start(Tag::Link { link_type, dest_url, title, id }) => {
            let safe = (dest_url.starts_with('/') && !dest_url.starts_with("//"))
                || url::Url::parse(&dest_url).is_ok_and(|u| matches!(u.scheme(), "https" | "http"));
            Some(Event::Start(Tag::Link { link_type, dest_url: if safe { dest_url } else { "".into() }, title, id }))
        }
        Event::Start(Tag::Image { .. }) | Event::End(TagEnd::Image) => None,
        other => Some(other),
    });
    html::push_html(&mut output, parser);
    output
}
