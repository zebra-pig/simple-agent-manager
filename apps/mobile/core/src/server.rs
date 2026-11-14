//! Which SAM deployment the app talks to. SAM is self-hostable, so the user
//! picks the server; the API lives on `api.<domain>`, the web app on `app.<domain>`.

use url::Url;

use crate::error::{CoreError, Result};

/// The hosted SAM. Self-hosters type their own.
pub const DEFAULT_SERVER_URL: &str = "https://api.simple-agent-manager.org";

/// What the user typed -> the API origin, e.g. `app.example.com/projects`
/// -> `https://api.example.com`. Plain http only for local development.
pub fn normalize(input: &str) -> Result<String> {
    let trimmed = input.trim();
    let invalid = || CoreError::Server(format!("\"{trimmed}\" is not a server address"));
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
        _ => return Err(CoreError::Server("The server address must start with https://".into())),
    }
    // People paste the web app's address; its API is the sibling host.
    let host = match host.strip_prefix("app.") {
        Some(rest) => format!("api.{rest}"),
        None => host.to_owned(),
    };
    let port = url.port().map(|p| format!(":{p}")).unwrap_or_default();
    Ok(format!("{}://{host}{port}", url.scheme()))
}

#[cfg(test)]
mod tests {
    use super::normalize;

    #[test]
    fn normalizes_what_people_type() {
        assert_eq!(normalize("https://api.simple-agent-manager.org/").unwrap(), "https://api.simple-agent-manager.org");
        assert_eq!(normalize(" app.example.com/projects ").unwrap(), "https://api.example.com");
        assert_eq!(normalize("sam.example.com").unwrap(), "https://sam.example.com");
        assert_eq!(normalize("http://localhost:8787").unwrap(), "http://localhost:8787");
        assert!(normalize("http://api.example.com").is_err());
        assert!(normalize("").is_err());
        assert!(normalize("ftp://example.com").is_err());
    }
}
