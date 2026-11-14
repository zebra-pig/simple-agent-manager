#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("Can't reach SAM: {0}")]
    Network(#[from] reqwest::Error),
    #[error("Your session has ended. Please sign in again.")]
    Unauthenticated,
    #[error("{0}")]
    Server(String),
}

pub type Result<T> = std::result::Result<T, CoreError>;
