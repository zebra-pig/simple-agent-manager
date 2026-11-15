//! First-boot setup, following the web chat's provisioning tracker. A queued
//! wake and a provider admission hold must not look like a new VM being built.
use serde::Deserialize;

use crate::api::{ChatSession, SessionStatus, TaskSummary};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ProvisioningStep {
    Waiting,
    NodeSelection,
    WaitingForNodeCapacity,
    NodeProvisioning,
    NodeAgentReady,
    WorkspaceCreation,
    WorkspaceDispatch,
    WorkspaceReady,
    AttachmentTransfer,
    AgentSession,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ProvisioningState {
    /// Zero-based index in the web's four-stage setup track.
    pub stage: u32,
    pub step: ProvisioningStep,
    pub started_at: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProvisioningTask {
    #[serde(flatten)]
    pub task: TaskSummary,
    pub started_at: Option<String>,
    pub admission_state: Option<String>,
}

impl ProvisioningTask {
    pub fn state(&self, session: &ChatSession) -> Option<ProvisioningState> {
        if session.status != SessionStatus::Active
            || !matches!(self.task.status.as_str(), "queued" | "delegated")
            || self.started_at.is_some()
            || self.admission_state.as_deref().is_some_and(|s| s.starts_with("provider_limit_"))
        {
            return None;
        }
        use ProvisioningStep::*;
        let (stage, step) = match self.task.execution_step.as_deref() {
            Some("node_selection") => (0, NodeSelection),
            Some("waiting_for_node_capacity") => (0, WaitingForNodeCapacity),
            Some("node_provisioning") => (0, NodeProvisioning),
            Some("node_agent_ready") => (0, NodeAgentReady),
            Some("workspace_creation") => (1, WorkspaceCreation),
            Some("workspace_dispatch") => (1, WorkspaceDispatch),
            Some("workspace_ready") => (2, WorkspaceReady),
            Some("attachment_transfer") => (2, AttachmentTransfer),
            Some("agent_session") => (3, AgentSession),
            Some("running" | "awaiting_followup") => return None,
            _ => (0, Waiting),
        };
        Some(ProvisioningState { stage, step, started_at: session.started_at })
    }
}
