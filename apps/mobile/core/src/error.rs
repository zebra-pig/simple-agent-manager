//! Errors. `CoreError` is internal; screens get a `UserError`, which carries no
//! wording: each shell turns it into localized copy (Localizable.xcstrings on
//! Apple platforms, strings.xml on Android). Keep user-facing text out of the core.

#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("network: {0}")]
    Network(#[from] reqwest::Error),
    #[error("session ended")]
    Unauthenticated,
    #[error("invalid server address: {0}")]
    InvalidServer(String),
    #[error("server address must use https")]
    HttpsRequired,
    #[error("sign-in code expired")]
    SignInExpired,
    /// A message written by the SAM server (its own copy, shown as is).
    #[error("server: {0}")]
    Server(String),
    /// Anything else: a technical detail for logs and bug reports, not copy.
    #[error("unexpected: {0}")]
    Unexpected(String),
}

pub type Result<T> = std::result::Result<T, CoreError>;

/// What a screen shows when something went wrong. The shell owns the wording.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum UserError {
    /// SAM could not be reached. `detail` is technical (for bug reports).
    Offline { detail: String },
    /// The session ended; the user has to sign in again.
    SessionEnded,
    /// What the user typed is not a server address.
    InvalidServer { input: String },
    /// The server address is plain http (only allowed for local development).
    HttpsRequired,
    /// The device sign-in code expired before it was approved.
    SignInExpired,
    /// The server's own message, already written for people.
    Server { message: String },
    /// Unexpected response. `detail` is technical (for bug reports).
    Unexpected { detail: String },
}

impl From<&CoreError> for UserError {
    fn from(e: &CoreError) -> Self {
        match e {
            CoreError::Network(e) => UserError::Offline { detail: e.to_string() },
            CoreError::Unauthenticated => UserError::SessionEnded,
            CoreError::InvalidServer(input) => UserError::InvalidServer { input: input.clone() },
            CoreError::HttpsRequired => UserError::HttpsRequired,
            CoreError::SignInExpired => UserError::SignInExpired,
            CoreError::Server(message) => UserError::Server { message: message.clone() },
            CoreError::Unexpected(detail) => UserError::Unexpected { detail: detail.clone() },
        }
    }
}
