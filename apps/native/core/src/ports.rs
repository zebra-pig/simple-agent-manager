//! Workspace ports and browser grants. Grants are returned only to the opener,
//! never retained in observable state or used as share links.
use crate::{
    error::{CoreError, UserError},
    session::seg,
};
use serde::Deserialize;

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct PortsState {
    pub workspace_id: String,
    pub generation: u64,
    pub ports: Vec<ServerPort>,
    pub public_enabled: bool,
    pub loaded: bool,
    pub loading: bool,
    pub saving: bool,
    pub opening: Option<u16>,
    pub readiness: String,
    pub error: Option<UserError>,
}
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
pub struct ServerPort {
    pub port: u16,
    pub label: String,
    pub url: String,
}
#[derive(Deserialize)]
struct PortList {
    ports: Vec<ServerPort>,
    #[serde(default = "ready")]
    state: String,
}
fn ready() -> String {
    "ready".into()
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Visibility {
    #[serde(default)]
    ports_public_enabled: bool,
}
#[derive(Deserialize)]
struct Grant {
    url: String,
}

observable!(PortsViewModel, PortsState, PortsObserver);

#[uniffi::export(async_runtime = "tokio")]
impl PortsViewModel {
    pub fn load(&self, workspace_id: String) {
        self.update(|s| *s = PortsState { workspace_id, generation: s.generation + 1, ..Default::default() });
    }
    pub async fn refresh(&self) {
        let mut admitted = None;
        self.update(|s| {
            if !s.loading && !s.saving && s.opening.is_none() && !s.workspace_id.is_empty() {
                s.loading = true;
                s.error = None;
                admitted = Some(s.clone());
            }
        });
        let Some(snapshot) = admitted else {
            return;
        };
        let id = snapshot.workspace_id;
        let base = format!("/api/workspaces/{}", seg(&id));
        let result: crate::error::Result<(Visibility, PortList)> = async {
            let visibility = self.app.get(&base).await?;
            let ports = self.app.get(&format!("{base}/ports")).await?;
            Ok((visibility, ports))
        }
        .await;
        self.update(|s| {
            if s.workspace_id != id || s.generation != snapshot.generation {
                return;
            }
            s.loading = false;
            match result {
                Ok((visibility, mut list)) => {
                    list.ports.sort_by_key(|p| p.port);
                    // Only canonical SAM port origins may be opened or shared.
                    list.ports.retain(|p| valid_url(&p.url, &id, p.port, &self.app.state().server_url));
                    for port in &mut list.ports {
                        let mut clean = reqwest::Url::parse(&port.url).unwrap();
                        clean.set_query(None);
                        clean.set_fragment(None);
                        clean.set_path("/");
                        port.url = clean.to_string();
                    }
                    s.ports = list.ports;
                    s.readiness = list.state;
                    s.public_enabled = visibility.ports_public_enabled;
                    s.loaded = true;
                }
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
    }
    pub async fn set_public(&self, enabled: bool) {
        let mut admitted = None;
        self.update(|s| {
            if s.loaded && !s.loading && !s.saving && s.opening.is_none() {
                s.saving = true;
                s.error = None;
                admitted = Some(s.clone());
            }
        });
        let Some(snapshot) = admitted else {
            return;
        };
        let id = snapshot.workspace_id;
        let result: crate::error::Result<Visibility> =
            self.app.patch(&format!("/api/workspaces/{}/ports-public", seg(&id)), &serde_json::json!({"enabled": enabled})).await;
        self.update(|s| {
            if s.workspace_id != id || s.generation != snapshot.generation {
                return;
            }
            s.saving = false;
            match result {
                Ok(v) => s.public_enabled = v.ports_public_enabled,
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
    }
    /// Uses the native login cookie to mint a port-scoped browser grant. The
    /// browser exchanges port_token for its own HttpOnly cookie and removes it.
    pub async fn open_port(&self, port: u16) -> Option<String> {
        let mut admitted = None;
        self.update(|s| {
            if s.loaded && !s.loading && !s.saving && s.opening.is_none() && s.ports.iter().any(|p| p.port == port) {
                s.opening = Some(port);
                s.error = None;
                admitted = Some(s.clone());
            }
        });
        let snapshot = admitted?;
        let id = snapshot.workspace_id;
        let result: crate::error::Result<Grant> = self.app.get(&format!("/api/workspaces/{}/port-access?port={port}", seg(&id))).await;
        let mut url = None;
        self.update(|s| {
            if s.workspace_id != id || s.generation != snapshot.generation {
                return;
            }
            s.opening = None;
            match result {
                Ok(grant) if valid_url(&grant.url, &id, port, &self.app.state().server_url) => url = Some(grant.url),
                Ok(_) => s.error = Some(UserError::from(&CoreError::Unexpected("Invalid port origin".into()))),
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
        url
    }
}
fn valid_url(value: &str, workspace: &str, port: u16, server: &str) -> bool {
    let (Ok(url), Ok(api)) = (reqwest::Url::parse(value), reqwest::Url::parse(server)) else {
        return false;
    };
    let Some(host) = api.host_str() else {
        return false;
    };
    let domain = host.strip_prefix("api.").unwrap_or(host);
    url.scheme() == "https"
        && url.host_str() == Some(format!("ws-{}--{port}.{domain}", workspace.to_lowercase()).as_str())
        && url.username().is_empty()
        && url.password().is_none()
        && url.port().is_none()
}
