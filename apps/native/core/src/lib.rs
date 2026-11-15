//! SAM native core: everything that isn't UI, exported to Swift and Kotlin with
//! UniFFI (README.md in apps/native).
//!
//! MVVM: each screen owns a Rust view model; the shell pulls the first snapshot
//! with `state()`, sends intents, and gets every later snapshot pushed through
//! its observer. Observers may fire on a worker thread, so shells hop to the
//! main thread inside their impl.

#[macro_use]
mod vm;
mod agent_profiles;
mod api;
#[macro_use]
mod attachments;
mod chat;
mod error;
mod project;
mod project_management;
mod projects;
pub use project_management::*;
mod provisioning;
mod server;
mod session;

pub use agent_profiles::{
    permission_modes, profile_draft, profile_runtimes, supported_efforts, task_modes, workspace_profiles, AgentOption, AgentProfile,
    ProfileDraft, ProfileNumberField,
};
pub use api::{ChatMessage, ChatSession, MessageRole, Project, SessionStatus, SubmittedTask, TaskSummary, Viewer};
pub use attachments::{
    Attachment, AttachmentSource, AttachmentStatus, ATTACHMENT_BATCH_MAX_BYTES, ATTACHMENT_MAX_BYTES, ATTACHMENT_MAX_FILES,
};
pub use chat::*;
pub use error::UserError;
pub use project::*;
pub use projects::*;
pub use provisioning::{ProvisioningState, ProvisioningStep};
pub use server::deployment_name;
pub use session::*;

uniffi::setup_scaffolding!();
