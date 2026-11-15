//! Project creation and general settings, using the same contracts as the web.
use crate::{
    api::Project,
    error::{Result, UserError},
    session::seg,
};
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Debug, Clone, Default, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ProjectDetails {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub repository: String,
    #[serde(default)]
    pub default_branch: String,
    #[serde(default)]
    pub repo_provider: String,
}
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ProjectInstallation {
    pub id: String,
    pub account_name: String,
}
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ProjectRepository {
    pub id: u64,
    #[serde(alias = "pathWithNamespace")]
    pub full_name: String,
    pub default_branch: String,
}
#[derive(Deserialize)]
struct Repositories {
    repositories: Vec<ProjectRepository>,
    #[serde(default, rename = "failedInstallations")]
    failed_installations: Vec<String>,
}
#[derive(Deserialize)]
struct GitLabProjects {
    projects: Vec<ProjectRepository>,
}
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ProjectDraft {
    pub name: String,
    pub description: String,
    pub provider: String,
    pub installation_id: String,
    pub repository_id: Option<u64>,
    pub repository: String,
    pub default_branch: String,
}
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ProjectManagementState {
    pub project: Option<ProjectDetails>,
    pub installations: Vec<ProjectInstallation>,
    pub repositories: Vec<ProjectRepository>,
    pub artifacts_enabled: bool,
    pub initialized: bool,
    pub loading: bool,
    pub saving: bool,
    pub error: Option<UserError>,
}
observable!(ProjectManagementViewModel, ProjectManagementState, ProjectManagementObserver, Option<(String, String, String)>);
#[uniffi::export(async_runtime = "tokio")]
impl ProjectManagementViewModel {
    pub async fn load(&self, project_id: Option<String>) {
        let mut begin = false;
        self.update_data(|s, source| {
            if !s.loading && !s.saving {
                *source = None;
                *s = ProjectManagementState { loading: true, ..Default::default() };
                begin = true;
            }
        });
        if !begin {
            return;
        }
        let result: Result<()> = async {
            if let Some(id) = project_id {
                let p = self.app.get::<ProjectDetails>(&format!("/api/projects/{}", seg(&id))).await?;
                self.update(|s| s.project = Some(p));
            } else {
                let (installations, artifacts) = tokio::join!(
                    self.app.get::<Vec<ProjectInstallation>>("/api/github/installations"),
                    self.app.get::<Value>("/api/config/artifacts-enabled")
                );
                self.update(|s| s.artifacts_enabled = artifacts.ok().and_then(|v| v["enabled"].as_bool()).unwrap_or(false));
                let installations = installations?;
                self.update(|s| s.installations = installations);
            }
            Ok(())
        }
        .await;
        self.update(|s| {
            s.loading = false;
            s.initialized = result.is_ok();
            s.error = result.err().map(|e| UserError::from(&e));
        });
    }
    pub async fn load_repositories(&self, provider: String, installation_id: String, search: String) {
        let mut begin = false;
        self.update_data(|s, source| {
            if !s.loading && !s.saving {
                s.loading = true;
                s.error = None;
                let key = (provider.clone(), installation_id.clone(), search.clone());
                if source.as_ref() != Some(&key) {
                    s.repositories.clear();
                }
                *source = Some(key);
                begin = true;
            }
        });
        if !begin {
            return;
        }
        let result = if provider == "gitlab" {
            self.app
                .get::<GitLabProjects>(&format!("/api/gitlab/projects?search={}", seg(search.trim())))
                .await
                .map(|p| (p.projects, false))
        } else {
            self.app
                .get::<Repositories>(&format!("/api/github/repositories?installation_id={}", seg(&installation_id)))
                .await
                .map(|p| (p.repositories, !p.failed_installations.is_empty()))
        };
        self.update(|s| {
            s.loading = false;
            match result {
                Ok((repos, failed)) => {
                    s.repositories = repos;
                    if failed {
                        s.error = Some(UserError::RepositoryAccessFailed);
                    }
                }
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
    }
    /// PATCH carries only general settings, preserving infrastructure and agent defaults.
    pub async fn save(&self, draft: ProjectDraft) -> Option<Project> {
        if draft.name.trim().is_empty() || draft.default_branch.trim().is_empty() {
            return None;
        }
        let state = self.state();
        if state.loading || state.saving {
            return None;
        }
        let mut body = json!({"name":draft.name.trim(),"description":draft.description.trim(),"defaultBranch":draft.default_branch.trim()});
        if state.project.is_none() {
            match draft.provider.as_str() {
                "artifacts" if state.artifacts_enabled => {
                    body["repoProvider"] = json!("artifacts");
                    body["defaultBranch"] = json!("main");
                }
                "gitlab" if draft.repository_id.is_some() => {
                    body["repoProvider"] = json!("gitlab");
                    body["gitlabProjectId"] = json!(draft.repository_id);
                }
                "github" if !draft.installation_id.is_empty() && !draft.repository.is_empty() => {
                    body["repoProvider"] = json!("github");
                    body["installationId"] = json!(draft.installation_id);
                    body["repository"] = json!(draft.repository);
                    body["githubRepoId"] = json!(draft.repository_id);
                }
                _ => return None,
            }
        }
        let mut begin = false;
        self.update(|s| {
            if !s.saving && !s.loading {
                s.saving = true;
                s.error = None;
                begin = true;
            }
        });
        if !begin {
            return None;
        }
        let result: Result<Project> = match state.project {
            Some(p) => self.app.patch(&format!("/api/projects/{}", seg(&p.id)), &body).await,
            None => self.app.post("/api/projects", &body).await,
        };
        self.update(|s| {
            s.saving = false;
            s.error = result.as_ref().err().map(UserError::from);
        });
        result.ok()
    }
    /// Typed confirmation is enforced here as well as in both shells.
    pub async fn delete(&self, confirmation: String) -> bool {
        let state = self.state();
        let Some(p) = state.project else {
            return false;
        };
        if confirmation != p.name || state.loading {
            return false;
        }
        let mut begin = false;
        self.update(|s| {
            if !s.saving && !s.loading {
                s.saving = true;
                s.error = None;
                begin = true;
            }
        });
        if !begin {
            return false;
        }
        let result: Result<Value> = self.app.delete(&format!("/api/projects/{}", seg(&p.id))).await;
        self.update(|s| {
            s.saving = false;
            s.error = result.as_ref().err().map(UserError::from);
        });
        result.is_ok()
    }
}
