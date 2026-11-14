//! Which SAM deployment the app talks to. SAM is self-hostable, so the user
//! picks the server; the API lives on `api.<domain>`, the web app on `app.<domain>`.

use url::Url;

use crate::error::{CoreError, Result};

/// The hosted SAM's `BASE_DOMAIN`. Builds can preset another one (white-label or
/// self-hosted); users can still type any server.
pub const DEFAULT_BASE_DOMAIN: &str = "simple-agent-manager.org";

/// The API origin for a deployment's `BASE_DOMAIN`, the same way the platform
/// derives it: `https://api.${BASE_DOMAIN}`.
pub fn api_origin(base_domain: &str) -> Result<String> {
    let domain = base_domain.trim();
    if domain.is_empty() || domain.contains(['/', ':', ' ']) {
        return Err(CoreError::InvalidServer(domain.to_owned()));
    }
    normalize(domain)
}

/// The deployment's name for people: `https://api.example.com` -> `example.com`.
#[uniffi::export]
pub fn deployment_name(server_url: &str) -> String {
    let host = server_url.split("://").nth(1).unwrap_or(server_url);
    host.strip_prefix("api.").unwrap_or(host).to_owned()
}

/// What the user typed -> the API origin. SAM serves its API on `api.${BASE_DOMAIN}`,
/// so the base domain (`example.com`), the web app (`app.example.com/projects`) and
/// the API itself all map to `https://api.example.com`. Plain http (and hosts
/// used as-is) only for local development.
pub fn normalize(input: &str) -> Result<String> {
    let trimmed = input.trim();
    let invalid = || CoreError::InvalidServer(trimmed.to_owned());
    if trimmed.is_empty() {
        return Err(invalid());
    }
    let with_scheme = if trimmed.contains("://") { trimmed.to_owned() } else { format!("https://{trimmed}") };
    let url = Url::parse(&with_scheme).map_err(|_| invalid())?;
    let host = url.host_str().ok_or_else(invalid)?;
    let local = host == "localhost" || host == "127.0.0.1" || host == "10.0.2.2";
    match url.scheme() {
        "https" => {}
        "http" if local => {}
        _ => return Err(CoreError::HttpsRequired),
    }
    let host =
        if local || host.starts_with("api.") { host.to_owned() } else { format!("api.{}", host.strip_prefix("app.").unwrap_or(host)) };
    let port = url.port().map(|p| format!(":{p}")).unwrap_or_default();
    Ok(format!("{}://{host}{port}", url.scheme()))
}

#[cfg(test)]
mod tests {
    use super::{api_origin, deployment_name, normalize};

    #[test]
    fn names_the_deployment() {
        assert_eq!(deployment_name("https://api.simple-agent-manager.org"), "simple-agent-manager.org");
        assert_eq!(deployment_name("http://localhost:8787"), "localhost:8787");
    }

    #[test]
    fn derives_the_api_from_base_domain() {
        assert_eq!(api_origin("simple-agent-manager.org").unwrap(), "https://api.simple-agent-manager.org");
        assert_eq!(api_origin(" sam.example.com ").unwrap(), "https://api.sam.example.com");
        assert!(api_origin("https://example.com").is_err());
        assert!(api_origin("").is_err());
    }

    #[test]
    fn normalizes_what_people_type() {
        assert_eq!(normalize("https://api.simple-agent-manager.org/").unwrap(), "https://api.simple-agent-manager.org");
        assert_eq!(normalize(" app.example.com/projects ").unwrap(), "https://api.example.com");
        assert_eq!(normalize("sam.example.com").unwrap(), "https://api.sam.example.com");
        assert_eq!(normalize("api.example.com").unwrap(), "https://api.example.com");
        assert_eq!(normalize("http://localhost:8787").unwrap(), "http://localhost:8787");
        assert!(normalize("http://api.example.com").is_err());
        assert!(normalize("").is_err());
        assert!(normalize("ftp://example.com").is_err());
    }
}
