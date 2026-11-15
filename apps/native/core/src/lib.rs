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
mod assistant;
mod chat;
pub use assistant::*;
mod notifications;
pub use notifications::*;
mod documents;
mod chat_tools;
mod error;
mod markdown;
mod project;
mod projects;
mod provisioning;
mod server;
mod session;
mod timeline;

pub use agent_profiles::{
    permission_modes, profile_draft, profile_runtimes, supported_efforts, task_modes, workspace_profiles, AgentOption, AgentProfile,
    ProfileDraft, ProfileNumberField,
};
pub use api::{ChatSession, Project, SessionStatus, SubmittedTask, TaskSummary, Viewer};
pub use attachments::{
    Attachment, AttachmentSource, AttachmentStatus, ATTACHMENT_BATCH_MAX_BYTES, ATTACHMENT_MAX_BYTES, ATTACHMENT_MAX_FILES,
};
pub use chat::*;
pub use documents::ChatDocument;
pub use chat_tools::*;
pub use error::UserError;
pub use markdown::{Block, ListMarker, Span, TableRow};
pub use project::*;
pub use projects::*;
pub use provisioning::{ProvisioningState, ProvisioningStep};
pub use server::deployment_name;
pub use session::*;
pub use timeline::{
    ActivityStep, ActivitySummary, ChatContent, ChatItem, ChatNotice, NoticeSeverity, NoticeSource, PlanEntry, PlanStatus, ToolCall,
    ToolKind, ToolStatus,
};

uniffi::setup_scaffolding!();
