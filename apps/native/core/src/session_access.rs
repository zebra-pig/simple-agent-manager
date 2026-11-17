//! Shared chat access, on the same `/sessions/:id/access` routes as web's Share
//! dialog. Grants are per person and always time-limited; the server enforces
//! eligibility, cascades and caps, so this mirrors its rules only to decide
//! which controls to offer.
use crate::{error::UserError, members, session::seg};
use serde::Serialize;
use serde_json::Value;

/// The only durations the server accepts, in minutes. There is no default.
pub const SHARE_DURATIONS: [u32; 4] = [5, 10, 30, 60];

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ViewerAccess {
    Owner,
    Grantee,
    Reader,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AccessPerson {
    pub id: String,
    pub name: Option<String>,
    pub is_viewer: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AccessGrant {
    pub id: String,
    pub grantee: AccessPerson,
    pub granted_by: AccessPerson,
    pub created_at: i64,
    pub expires_at: i64,
    pub duration_minutes: u32,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ShareCandidate {
    pub user_id: String,
    pub label: String,
    pub email: Option<String>,
}

/// Why nobody can be added, for the shell's empty state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NoCandidates {
    NobodyElse,
    OnlyViewers,
    EveryoneHasAccess,
}

/// What the last successful change did, for a confirmation line.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ShareOutcome {
    Granted { name: String, until: i64 },
    Renewed { name: String, until: i64 },
    AlreadyShared { name: String, until: i64 },
    Revoked { name: String, cascaded: u32, cancelled_messages: u32 },
    Left { cascaded: u32, cancelled_messages: u32 },
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct SessionAccessState {
    pub project_id: String,
    pub session_id: String,
    pub loaded: bool,
    pub viewer_access: Option<ViewerAccess>,
    pub owner: Option<AccessPerson>,
    /// Active grants, oldest first.
    pub grants: Vec<AccessGrant>,
    /// Owner or grantee.
    pub can_manage: bool,
    /// The chat is active or sleeping: new people may be added.
    pub can_add: bool,
    /// Only the owner renews.
    pub can_renew: bool,
    pub candidates: Vec<ShareCandidate>,
    pub no_candidates: Option<NoCandidates>,
    /// When the viewer's own grant ends: a new grant cannot outlast it.
    pub viewer_expires_at: Option<i64>,
    /// Server clock minus device clock, for "ends in" countdowns.
    pub server_offset_ms: i64,
    pub outcome: Option<ShareOutcome>,
    pub loading: bool,
    pub saving: bool,
    pub error: Option<UserError>,
}

observable!(SessionAccessViewModel, SessionAccessState, SessionAccessObserver);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GrantRequest<'a> {
    user_id: &'a str,
    duration_minutes: u32,
    acknowledge_shared_credentials: bool,
}

#[uniffi::export(async_runtime = "tokio")]
impl SessionAccessViewModel {
    /// `shareable`: the chat is active or sleeping (`isShareableChatSessionStatus`).
    pub async fn load(&self, project_id: String, session_id: String, shareable: bool) {
        self.update(|s| {
            if s.project_id != project_id || s.session_id != session_id {
                *s = SessionAccessState { project_id: project_id.clone(), session_id: session_id.clone(), ..Default::default() };
            }
            s.can_add = shareable;
            s.loading = true;
            s.error = None;
        });
        let path = format!("{}/access", base(&project_id, &session_id));
        let (access, members) = tokio::join!(self.app.get::<Value>(&path), members::project_members(&self.app, &project_id),);
        let viewer = self.viewer();
        self.update(|s| {
            if s.project_id != project_id || s.session_id != session_id {
                return;
            }
            s.loading = false;
            match access {
                Ok(body) => {
                    apply(s, &body, &viewer);
                    s.loaded = true;
                    match members {
                        Ok(members) => candidates(s, &members, &viewer),
                        Err(e) => s.error = Some(UserError::from(&e)),
                    }
                }
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
    }

    /// Adds or renews one person. `acknowledged`: the viewer confirmed it runs
    /// on the owner's accounts; the request is refused without it.
    pub async fn grant(&self, user_id: String, duration_minutes: u32, acknowledged: bool) -> bool {
        if !acknowledged || !SHARE_DURATIONS.contains(&duration_minutes) {
            return false;
        }
        let Some(state) = self.claim(|s| s.can_manage && (s.can_add || (s.can_renew && s.grants.iter().any(|g| g.grantee.id == user_id))))
        else {
            return false;
        };
        let name = state
            .grants
            .iter()
            .find(|g| g.grantee.id == user_id)
            .and_then(|g| g.grantee.name.clone())
            .or_else(|| state.candidates.iter().find(|c| c.user_id == user_id).map(|c| c.label.clone()))
            .unwrap_or_else(|| user_id.clone());
        let result: crate::error::Result<Value> = self
            .app
            .post(
                &format!("{}/access/grants", base(&state.project_id, &state.session_id)),
                &GrantRequest { user_id: &user_id, duration_minutes, acknowledge_shared_credentials: true },
            )
            .await;
        self.settle(&state, result, |body| {
            let until = body["grant"]["expiresAt"].as_i64().unwrap_or(0);
            let name = name.clone();
            if body["renewed"].as_bool() == Some(true) {
                ShareOutcome::Renewed { name, until }
            } else if body["created"].as_bool() == Some(true) {
                ShareOutcome::Granted { name, until }
            } else {
                ShareOutcome::AlreadyShared { name, until }
            }
        })
        .await
    }

    /// Revokes someone's access, or leaves when `user_id` is the viewer.
    pub async fn revoke(&self, user_id: String) -> bool {
        let viewer = self.viewer();
        let leaving = user_id == viewer;
        let Some(state) = self.claim(|s| s.grants.iter().any(|g| g.grantee.id == user_id) && (leaving || s.can_manage)) else {
            return false;
        };
        let name =
            state.grants.iter().find(|g| g.grantee.id == user_id).and_then(|g| g.grantee.name.clone()).unwrap_or_else(|| user_id.clone());
        let result: crate::error::Result<Value> =
            self.app.delete(&format!("{}/access/grants/{}", base(&state.project_id, &state.session_id), seg(&user_id))).await;
        self.settle(&state, result, |body| {
            let cascaded = body["revokedGrantIds"].as_array().map(|a| a.len().saturating_sub(1) as u32).unwrap_or(0);
            let cancelled_messages = body["cancelledDeliveryIds"].as_array().map(|a| a.len() as u32).unwrap_or(0);
            if leaving {
                ShareOutcome::Left { cascaded, cancelled_messages }
            } else {
                ShareOutcome::Revoked { name: name.clone(), cascaded, cancelled_messages }
            }
        })
        .await
    }

    pub fn clear_outcome(&self) {
        self.update(|s| s.outcome = None);
    }
}

impl SessionAccessViewModel {
    fn viewer(&self) -> String {
        self.app.state().viewer.map(|v| v.id).unwrap_or_default()
    }

    fn claim(&self, allowed: impl FnOnce(&SessionAccessState) -> bool) -> Option<SessionAccessState> {
        let mut claimed = None;
        self.update(|s| {
            if s.saving || !s.loaded || !allowed(s) {
                return;
            }
            s.saving = true;
            s.error = None;
            s.outcome = None;
            claimed = Some(s.clone());
        });
        claimed
    }

    async fn settle(
        &self,
        state: &SessionAccessState,
        result: crate::error::Result<Value>,
        outcome: impl Fn(&Value) -> ShareOutcome,
    ) -> bool {
        let viewer = self.viewer();
        let members = if result.is_ok() { members::project_members(&self.app, &state.project_id).await.ok() } else { None };
        let ok = result.is_ok();
        self.update(|s| {
            if s.project_id != state.project_id || s.session_id != state.session_id {
                return;
            }
            s.saving = false;
            match &result {
                Ok(body) => {
                    apply(s, &body["access"], &viewer);
                    s.outcome = Some(outcome(body));
                    if let Some(members) = &members {
                        candidates(s, members, &viewer);
                    }
                }
                Err(e) => s.error = Some(UserError::from(e)),
            }
        });
        ok
    }
}

fn base(project_id: &str, session_id: &str) -> String {
    format!("/api/projects/{}/sessions/{}", seg(project_id), seg(session_id))
}

fn person(v: &Value, viewer: &str) -> Option<AccessPerson> {
    let id = v["id"].as_str()?.to_owned();
    Some(AccessPerson { is_viewer: id == viewer, name: v["name"].as_str().map(str::trim).filter(|n| !n.is_empty()).map(str::to_owned), id })
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// Applies a `SessionAccessSummary`.
fn apply(s: &mut SessionAccessState, v: &Value, viewer: &str) {
    s.viewer_access = match v["viewerAccess"].as_str() {
        Some("owner") => Some(ViewerAccess::Owner),
        Some("grantee") => Some(ViewerAccess::Grantee),
        Some("reader") => Some(ViewerAccess::Reader),
        _ => None,
    };
    s.can_manage = matches!(s.viewer_access, Some(ViewerAccess::Owner | ViewerAccess::Grantee));
    s.can_renew = s.viewer_access == Some(ViewerAccess::Owner);
    s.owner = person(&v["owner"], viewer);
    s.grants = v["grants"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|g| {
            Some(AccessGrant {
                id: g["id"].as_str()?.to_owned(),
                grantee: person(&g["grantee"], viewer)?,
                granted_by: person(&g["grantedBy"], viewer).unwrap_or(AccessPerson { id: String::new(), name: None, is_viewer: false }),
                created_at: g["createdAt"].as_i64().unwrap_or(0),
                expires_at: g["expiresAt"].as_i64().unwrap_or(0),
                duration_minutes: g["durationMinutes"].as_u64().unwrap_or(0) as u32,
            })
        })
        .collect();
    s.grants.sort_by_key(|g| g.created_at);
    s.viewer_expires_at = s.grants.iter().find(|g| g.grantee.is_viewer).map(|g| g.expires_at);
    if let Some(server) = v["serverTime"].as_i64() {
        s.server_offset_ms = server - now_ms();
    }
}

/// Web's `SessionShareAddTeammate` candidate rules.
fn candidates(s: &mut SessionAccessState, members: &[members::ProjectMember], viewer: &str) {
    let owner = s.owner.as_ref().map(|o| o.id.as_str()).unwrap_or_default();
    let others: Vec<_> = members.iter().filter(|m| m.active && m.user_id != viewer && m.user_id != owner).collect();
    let eligible: Vec<_> = others.iter().filter(|m| m.role != "viewer").collect();
    let mut open: Vec<ShareCandidate> = eligible
        .iter()
        .filter(|m| !s.grants.iter().any(|g| g.grantee.id == m.user_id))
        .map(|m| ShareCandidate { user_id: m.user_id.clone(), label: m.label.clone(), email: m.email.clone() })
        .collect();
    open.sort_by_key(|c| c.label.to_lowercase());
    s.no_candidates = if !open.is_empty() {
        None
    } else if others.is_empty() {
        Some(NoCandidates::NobodyElse)
    } else if eligible.is_empty() {
        Some(NoCandidates::OnlyViewers)
    } else {
        Some(NoCandidates::EveryoneHasAccess)
    };
    s.candidates = open;
}

/// The latest a new grant of `minutes` can end: never past the viewer's own grant.
#[uniffi::export]
pub fn share_ends_at(state: &SessionAccessState, minutes: u32, now: i64) -> i64 {
    let end = now + minutes as i64 * 60_000;
    match state.viewer_expires_at {
        Some(limit) if state.viewer_access == Some(ViewerAccess::Grantee) => end.min(limit - state.server_offset_ms),
        _ => end,
    }
}

#[uniffi::export]
pub fn share_durations() -> Vec<u32> {
    SHARE_DURATIONS.to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn member(id: &str, role: &str) -> members::ProjectMember {
        members::ProjectMember { user_id: id.into(), role: role.into(), label: id.to_uppercase(), email: None, active: true }
    }

    #[test]
    fn candidates_exclude_viewer_owner_grantees_and_project_viewers() {
        let mut s = SessionAccessState::default();
        apply(
            &mut s,
            &json!({"viewerAccess": "grantee", "owner": {"id": "o", "name": "Owner"}, "grants": [{"id": "g", "grantee": {"id": "me"}, "grantedBy": {"id": "o"}, "createdAt": 1, "expiresAt": 99, "durationMinutes": 5}], "serverTime": 0}),
            "me",
        );
        assert!(s.can_manage && !s.can_renew);
        assert_eq!(s.viewer_expires_at, Some(99));
        candidates(
            &mut s,
            &[member("me", "admin"), member("o", "owner"), member("b", "maintainer"), member("a", "admin"), member("v", "viewer")],
            "me",
        );
        assert_eq!(s.candidates.iter().map(|c| c.user_id.as_str()).collect::<Vec<_>>(), ["a", "b"]);
        candidates(&mut s, &[member("me", "admin"), member("v", "viewer")], "me");
        assert_eq!(s.no_candidates, Some(NoCandidates::OnlyViewers));
        candidates(&mut s, &[member("me", "admin")], "me");
        assert_eq!(s.no_candidates, Some(NoCandidates::NobodyElse));
    }

    #[test]
    fn a_grantee_cannot_share_past_their_own_access() {
        let s = SessionAccessState { viewer_access: Some(ViewerAccess::Grantee), viewer_expires_at: Some(120_000), ..Default::default() };
        assert_eq!(share_ends_at(&s, 5, 0), 120_000);
        assert_eq!(share_ends_at(&s, 1, 0), 60_000);
        let owner = SessionAccessState { viewer_access: Some(ViewerAccess::Owner), viewer_expires_at: Some(1), ..Default::default() };
        assert_eq!(share_ends_at(&owner, 5, 0), 300_000);
    }
}
