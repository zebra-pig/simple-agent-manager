//! SAM native core: everything that isn't UI, exported to Swift and Kotlin with
//! UniFFI (README.md in apps/mobile).
//!
//! MVVM: each screen owns a Rust view model; the shell pulls the first snapshot
//! with `state()`, sends intents, and gets every later snapshot pushed through
//! its observer. Observers may fire on a worker thread, so shells hop to the
//! main thread inside their impl.

#[macro_use]
mod vm;
mod api;
mod chat;
mod error;
mod project;
mod projects;
mod server;
mod session;

pub use api::{ChatMessage, ChatSession, MessageRole, Project, SessionStatus, SubmittedTask, TaskSummary, Viewer};
pub use chat::*;
pub use error::UserError;
pub use project::*;
pub use projects::*;
pub use server::deployment_name;
pub use session::*;

uniffi::setup_scaffolding!();
