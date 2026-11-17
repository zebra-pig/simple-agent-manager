//! Message comments for one chat, on the same `/sessions/:id/comments` routes
//! as web. Threads are grouped into web's inbox buckets here, so both shells
//! agree on "Needs you", "With agent", "Open" and "Resolved".
use crate::{api::ChatSession, error::UserError, members, session::seg};
use serde::Serialize;
use serde_json::Value;

const LIMIT: u32 = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CommentStatus {
    Open,
    Sent,
    Resolved,
}

/// Web's inbox buckets, in display order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, uniffi::Enum)]
pub enum CommentBucket {
    NeedsYou,
    WithAgent,
    Open,
    Resolved,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CommentAuthor {
    pub id: String,
    pub name: Option<String>,
    pub is_agent: bool,
    pub is_viewer: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CommentReply {
    pub id: String,
    pub author: CommentAuthor,
    pub body: String,
    pub created_at: i64,
    pub sent_to_agent: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CommentThread {
    pub id: String,
    pub message_id: String,
    pub quote: Option<String>,
    pub author: CommentAuthor,
    pub body: String,
    pub status: CommentStatus,
    pub bucket: CommentBucket,
    pub created_at: i64,
    /// The newest of the thread and its replies.
    pub last_activity_at: i64,
    pub replies: Vec<CommentReply>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, uniffi::Record)]
pub struct CommentCounts {
    pub all: u32,
    pub needs_you: u32,
    pub with_agent: u32,
    pub open: u32,
    pub resolved: u32,
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct CommentsState {
    pub project_id: String,
    pub session_id: String,
    pub loaded: bool,
    /// Newest activity first.
    pub threads: Vec<CommentThread>,
    pub counts: CommentCounts,
    /// More threads exist than were read.
    pub has_more: bool,
    /// May create, reply, resolve and reopen (`task:write`).
    pub can_comment: bool,
    /// Owner or grantee: may hand a comment to the agent.
    pub can_send_to_agent: bool,
    pub loading: bool,
    /// A mutation is in flight.
    pub saving: bool,
    pub error: Option<UserError>,
}

observable!(CommentsViewModel, CommentsState, CommentsObserver);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NewThread<'a> {
    message_id: &'a str,
    body: &'a str,
    quote: Option<&'a str>,
    client_mutation_id: &'a str,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NewReply<'a> {
    body: &'a str,
    client_mutation_id: &'a str,
}

#[uniffi::export(async_runtime = "tokio")]
impl CommentsViewModel {
    /// `session` is the chat's detail: its viewer access decides Send to agent.
    pub async fn load(&self, project_id: String, session: ChatSession) {
        let session_id = session.id.clone();
        self.update(|s| {
            if s.project_id != project_id || s.session_id != session_id {
                *s = CommentsState { project_id: project_id.clone(), session_id: session_id.clone(), ..Default::default() };
            }
            s.can_send_to_agent = session.can_drive();
            s.loading = true;
            s.error = None;
        });
        let viewer = self.app.state().viewer.map(|v| v.id).unwrap_or_default();
        let path = format!("/api/projects/{}/sessions/{}/comments?anchorKind=message&limit={LIMIT}", seg(&project_id), seg(&session_id));
        let (threads, members) = tokio::join!(
            self.app.get::<Value>(&path),
            members::project_members(&self.app, &project_id),
        );
        self.update(|s| {
            if s.project_id != project_id || s.session_id != session_id {
                return;
            }
            s.loading = false;
            s.can_comment = members.map(|m| members::can_write(&m, &viewer)).unwrap_or(false);
            match threads {
                Ok(body) => {
                    let rows = body["threads"].as_array().or_else(|| body["comments"].as_array());
                    s.threads = rows.into_iter().flatten().filter_map(|t| parse_thread(t, &viewer)).collect();
                    sort(&mut s.threads);
                    s.counts = counts(&s.threads);
                    s.has_more = body["hasMore"].as_bool().unwrap_or(false);
                    s.loaded = true;
                }
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
    }

    /// Starts a thread on a message; `send_to_agent` also hands it to the agent
    /// (web's "Comment & send"). `client_id` is one id per draft, for retries.
    pub async fn create(&self, message_id: String, quote: Option<String>, body: String, send_to_agent: bool, client_id: String) -> bool {
        let body = body.trim().to_owned();
        if body.is_empty() || message_id.is_empty() {
            return false;
        }
        let Some(state) = self.claim(send_to_agent) else { return false };
        let quote = quote.map(|q| q.trim().to_owned()).filter(|q| !q.is_empty());
        let result: crate::error::Result<Value> = self
            .app
            .post(
                &format!("{}/comments", base(&state)),
                &NewThread { message_id: &message_id, body: &body, quote: quote.as_deref(), client_mutation_id: &client_id },
            )
            .await;
        let result = match result {
            Ok(created) if send_to_agent => match created["thread"]["id"].as_str() {
                Some(id) => self.send_request(&state, id, Some(&body), &format!("{client_id}:send")).await,
                None => Err(crate::error::CoreError::Unexpected("Created comment has no id".into())),
            },
            other => other,
        };
        self.settle(state, result).await
    }

    pub async fn reply(&self, thread_id: String, body: String, send_to_agent: bool, client_id: String) -> bool {
        let body = body.trim().to_owned();
        if body.is_empty() {
            return false;
        }
        let Some(state) = self.claim(send_to_agent) else { return false };
        let mut result: crate::error::Result<Value> = self
            .app
            .post(&format!("{}/comments/{}/replies", base(&state), seg(&thread_id)), &NewReply { body: &body, client_mutation_id: &client_id })
            .await;
        if send_to_agent && result.is_ok() {
            result = self.send_request(&state, &thread_id, Some(&body), &format!("{client_id}:send")).await;
        }
        self.settle(state, result).await
    }

    /// Hands an open thread to the agent as a follow-up instruction.
    pub async fn send_to_agent(&self, thread_id: String, client_id: String) -> bool {
        let Some(state) = self.claim(true) else { return false };
        let result = self.send_request(&state, &thread_id, None, &client_id).await;
        self.settle(state, result).await
    }

    pub async fn resolve(&self, thread_id: String) -> bool {
        self.transition(thread_id, "resolve").await
    }

    pub async fn reopen(&self, thread_id: String) -> bool {
        self.transition(thread_id, "reopen").await
    }
}

impl CommentsViewModel {
    async fn transition(&self, thread_id: String, action: &str) -> bool {
        let Some(state) = self.claim(false) else { return false };
        let result: crate::error::Result<Value> =
            self.app.post(&format!("{}/comments/{}/{action}", base(&state), seg(&thread_id)), &serde_json::json!({})).await;
        self.settle(state, result).await
    }

    async fn send_request(&self, state: &CommentsState, thread_id: &str, body: Option<&str>, client_id: &str) -> crate::error::Result<Value> {
        let mut payload = serde_json::json!({"clientMutationId": client_id});
        if let Some(body) = body {
            payload["body"] = body.into();
        }
        self.app.post(&format!("{}/comments/{}/send", base(state), seg(thread_id)), &payload).await
    }

    fn claim(&self, send_to_agent: bool) -> Option<CommentsState> {
        let mut claimed = None;
        self.update(|s| {
            if s.saving || !s.loaded || !s.can_comment || (send_to_agent && !s.can_send_to_agent) {
                return;
            }
            s.saving = true;
            s.error = None;
            claimed = Some(s.clone());
        });
        claimed
    }

    /// Reports the outcome, then rereads the threads so the server stays the authority.
    async fn settle(&self, state: CommentsState, result: crate::error::Result<Value>) -> bool {
        let ok = result.is_ok();
        self.update(|s| {
            if s.project_id == state.project_id && s.session_id == state.session_id {
                s.saving = false;
                if let Err(e) = &result {
                    s.error = Some(UserError::from(e));
                }
            }
        });
        let viewer = self.app.state().viewer.map(|v| v.id).unwrap_or_default();
        let fresh: crate::error::Result<Value> =
            self.app.get(&format!("{}/comments?anchorKind=message&limit={LIMIT}", base(&state))).await;
        if let Ok(body) = fresh {
            self.update(|s| {
                if s.project_id == state.project_id && s.session_id == state.session_id {
                    let rows = body["threads"].as_array().or_else(|| body["comments"].as_array());
                    s.threads = rows.into_iter().flatten().filter_map(|t| parse_thread(t, &viewer)).collect();
                    sort(&mut s.threads);
                    s.counts = counts(&s.threads);
                    s.has_more = body["hasMore"].as_bool().unwrap_or(false);
                }
            });
        }
        ok
    }
}

fn base(s: &CommentsState) -> String {
    format!("/api/projects/{}/sessions/{}", seg(&s.project_id), seg(&s.session_id))
}

fn author(v: &Value, viewer: &str) -> CommentAuthor {
    let id = v["id"].as_str().unwrap_or_default().to_owned();
    let name = v["name"].as_str().or_else(|| v["displayName"].as_str()).map(str::trim).filter(|n| !n.is_empty()).map(str::to_owned);
    let is_agent = v["kind"].as_str() == Some("agent");
    CommentAuthor { is_viewer: !is_agent && !id.is_empty() && id == viewer, id, name, is_agent }
}

fn parse_thread(v: &Value, viewer: &str) -> Option<CommentThread> {
    let id = v["id"].as_str()?.to_owned();
    let message_id = v["anchor"]["messageId"].as_str().or_else(|| v["messageId"].as_str())?.to_owned();
    let status = match v["status"].as_str() {
        Some("sent") => CommentStatus::Sent,
        Some("resolved") => CommentStatus::Resolved,
        _ => CommentStatus::Open,
    };
    let mut replies: Vec<CommentReply> = v["replies"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| {
            Some(CommentReply {
                id: r["id"].as_str()?.to_owned(),
                author: author(&r["author"], viewer),
                body: r["body"].as_str().unwrap_or_default().to_owned(),
                created_at: r["createdAt"].as_i64().unwrap_or(0),
                sent_to_agent: r["sentToAgent"].as_bool().unwrap_or(false),
            })
        })
        .collect();
    replies.sort_by_key(|r| r.created_at);
    let author = author(&v["author"], viewer);
    let created_at = v["createdAt"].as_i64().unwrap_or(0);
    let last = replies.last();
    let last_actor_is_viewer = last.map(|r| r.author.is_viewer).unwrap_or(author.is_viewer);
    let bucket = match status {
        CommentStatus::Resolved => CommentBucket::Resolved,
        CommentStatus::Sent => CommentBucket::WithAgent,
        CommentStatus::Open if !last_actor_is_viewer => CommentBucket::NeedsYou,
        CommentStatus::Open => CommentBucket::Open,
    };
    let last_activity_at = last.map(|r| r.created_at).unwrap_or(0).max(v["lastReplyAt"].as_i64().unwrap_or(0)).max(created_at);
    Some(CommentThread {
        id,
        message_id,
        quote: v["anchor"]["quote"].as_str().map(str::trim).filter(|q| !q.is_empty()).map(str::to_owned),
        author,
        body: v["body"].as_str().unwrap_or_default().to_owned(),
        status,
        bucket,
        created_at,
        last_activity_at,
        replies,
    })
}

fn sort(threads: &mut [CommentThread]) {
    threads.sort_by(|a, b| b.last_activity_at.cmp(&a.last_activity_at).then_with(|| a.id.cmp(&b.id)));
}

fn counts(threads: &[CommentThread]) -> CommentCounts {
    let n = |b: CommentBucket| threads.iter().filter(|t| t.bucket == b).count() as u32;
    CommentCounts {
        all: threads.len() as u32,
        needs_you: n(CommentBucket::NeedsYou),
        with_agent: n(CommentBucket::WithAgent),
        open: n(CommentBucket::Open),
        resolved: n(CommentBucket::Resolved),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn buckets_follow_the_last_actor_and_status() {
        let thread = |status: &str, author: &str, reply_author: Option<&str>| {
            let replies: Vec<Value> = reply_author.into_iter().map(|a| json!({"id": "r", "author": {"kind": "human", "id": a}, "body": "", "createdAt": 5})).collect();
            parse_thread(&json!({"id": "t", "anchor": {"kind": "message", "messageId": "m", "quote": null}, "author": {"kind": "human", "id": author, "name": "A"}, "body": "b", "status": status, "createdAt": 1, "replies": replies}), "me").unwrap()
        };
        assert_eq!(thread("open", "me", None).bucket, CommentBucket::Open);
        assert_eq!(thread("open", "me", Some("you")).bucket, CommentBucket::NeedsYou);
        assert_eq!(thread("open", "you", Some("me")).bucket, CommentBucket::Open);
        assert_eq!(thread("sent", "you", None).bucket, CommentBucket::WithAgent);
        assert_eq!(thread("resolved", "you", None).bucket, CommentBucket::Resolved);
        assert_eq!(thread("open", "me", Some("you")).last_activity_at, 5);
    }

    #[test]
    fn accepts_display_name_alias_and_skips_unanchored_rows() {
        let t = parse_thread(&json!({"id": "t", "messageId": "m", "author": {"kind": "agent", "id": "a", "displayName": "Claude"}, "status": "open"}), "me").unwrap();
        assert_eq!(t.author.name.as_deref(), Some("Claude"));
        assert!(t.author.is_agent);
        assert!(parse_thread(&json!({"id": "t"}), "me").is_none());
    }
}
