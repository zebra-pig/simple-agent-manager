//! Project members (`GET /api/projects/:id/members`), shared by the chat tools
//! that need the viewer's write capability or a teammate picker.
use crate::session::{seg, App};
use serde::Deserialize;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ProjectMember {
    pub user_id: String,
    /// `owner`, `admin`, `maintainer` or `viewer`.
    pub role: String,
    /// Name, else email, else the id: what web shows.
    pub label: String,
    pub email: Option<String>,
    pub active: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MemberRow {
    user_id: String,
    #[serde(default)]
    role: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    user: Option<MemberUser>,
}
#[derive(Deserialize, Default)]
struct MemberUser {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    email: Option<String>,
}
#[derive(Deserialize)]
struct Members {
    #[serde(default)]
    members: Vec<MemberRow>,
}

pub(crate) async fn project_members(app: &App, project_id: &str) -> crate::error::Result<Vec<ProjectMember>> {
    let body: Members = app.get(&format!("/api/projects/{}/members", seg(project_id))).await?;
    Ok(body
        .members
        .into_iter()
        .map(|m| {
            let user = m.user.unwrap_or_default();
            let name = user.name.filter(|n| !n.trim().is_empty());
            let email = user.email.filter(|e| !e.trim().is_empty());
            ProjectMember {
                label: name.or_else(|| email.clone()).unwrap_or_else(|| m.user_id.clone()),
                user_id: m.user_id,
                role: m.role,
                email,
                active: m.status == "active",
            }
        })
        .collect())
}

/// `task:write`: owner, admin and maintainer; never a project viewer.
pub(crate) fn can_write(members: &[ProjectMember], viewer_id: &str) -> bool {
    members.iter().any(|m| m.user_id == viewer_id && m.active && m.role != "viewer")
}
