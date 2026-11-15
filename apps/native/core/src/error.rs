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
    /// An attached file could not be read on the device.
    #[error("file unreadable")]
    Unreadable,
    #[error("file is empty")]
    FileEmpty,
    #[error("file larger than {0} bytes")]
    FileTooLarge(u64),
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
    /// An attached file has no content.
    FileEmpty,
    /// An attached file is over the per-file limit.
    FileTooLarge { max_bytes: u64 },
    /// An attached file could not be read on the device (moved, deleted, no access).
    FileUnreadable,
    /// The message already has the most files it can carry.
    TooManyFiles { max: u32 },
    /// The files together would be over the per-message limit.
    AttachmentsTooLarge { max_bytes: u64 },
    /// Some files are still uploading or failed; remove the failed ones to send.
    AttachmentsNotReady,
    /// GitHub could not load repositories for one or more connected accounts.
    RepositoryAccessFailed,
    /// A profile needs a name.
    ProfileNameRequired,
    /// The profile's agent has no such effort level.
    EffortNotSupported,
    /// A number field of the profile editor holds something that isn't a valid value.
    InvalidProfileNumber { field: crate::agent_profiles::ProfileNumberField },
}

impl From<&CoreError> for UserError {
    fn from(e: &CoreError) -> Self {
        match e {
            CoreError::Network(e) => UserError::Offline { detail: e.to_string() },
            CoreError::Unauthenticated => UserError::SessionEnded,
            CoreError::InvalidServer(input) => UserError::InvalidServer { input: input.clone() },
            CoreError::HttpsRequired => UserError::HttpsRequired,
            CoreError::SignInExpired => UserError::SignInExpired,
            CoreError::Unreadable => UserError::FileUnreadable,
            CoreError::FileEmpty => UserError::FileEmpty,
            CoreError::FileTooLarge(max_bytes) => UserError::FileTooLarge { max_bytes: *max_bytes },
            CoreError::Server(message) => UserError::Server { message: message.clone() },
            CoreError::Unexpected(detail) => UserError::Unexpected { detail: detail.clone() },
        }
    }
}
