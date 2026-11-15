//! Poll the real chat view model against the API contract, including restore,
//! progress, task-fetch failures and the wake/admission gates shared with web.
mod common;

use std::sync::{Arc, Mutex};

use common::{serve, MemoryStore};
use sam_core::{App, ChatContent, ChatViewModel, Credentials, ProvisioningStep};
use serde_json::{json, Value};

#[tokio::test]
async fn setup_restores_progresses_and_disappears_when_the_agent_starts() {
    let task = Arc::new(Mutex::new(json!({"id":"t1", "status":"queued", "executionStep":"node_provisioning"})));
    let session_status = Arc::new(Mutex::new("active"));
    let fail_task = Arc::new(Mutex::new(false));
    let (t, s, f) = (task.clone(), session_status.clone(), fail_task.clone());
    let server = serve(Arc::new(move |r| match r.path.as_str() {
        "/api/projects/p1/sessions/s1" => (
            200,
            json!({
                "session": {"id":"s1", "status":*s.lock().unwrap(), "startedAt":1000, "taskId":"t1", "task":*t.lock().unwrap()},
                "messages":[{"id":"m1", "role":"user", "content":"Build an app", "createdAt":1000}]
            })
            .to_string(),
        ),
        "/api/projects/p1/tasks/t1" => {
            if *f.lock().unwrap() {
                (503, "{}".into())
            } else {
                (200, t.lock().unwrap().to_string())
            }
        }
        _ => (404, "{}".into()),
    }))
    .await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let vm = ChatViewModel::new(App::new(Box::new(store), None));
    vm.load("p1".into(), "s1".into()).await;
    let setup = vm.state().provisioning.unwrap();
    assert_eq!(setup.stage, 0);
    assert_eq!(setup.step, ProvisioningStep::NodeProvisioning);
    assert_eq!(setup.started_at, 1000);
    assert_eq!(vm.state().items[0].content, ChatContent::User { text: "Build an app".into(), attachments: vec![] });

    for (step, stage) in
        [("workspace_creation", 1), ("workspace_dispatch", 1), ("workspace_ready", 2), ("attachment_transfer", 2), ("agent_session", 3)]
    {
        task.lock().unwrap()["executionStep"] = json!(step);
        vm.refresh().await;
        assert_eq!(vm.state().provisioning.unwrap().stage, stage);
    }
    *fail_task.lock().unwrap() = true;
    vm.refresh().await;
    assert_eq!(vm.state().provisioning.unwrap().stage, 3);
    assert!(vm.state().error.is_none());
    *fail_task.lock().unwrap() = false;

    // First boot isn't a wake, and provider holds don't provision a server.
    for (key, value) in [("startedAt", json!("2026-11-15T00:00:00Z")), ("admissionState", json!("provider_limit_waiting"))] {
        task.lock().unwrap()[key] = value;
        vm.refresh().await;
        assert!(vm.state().provisioning.is_none(), "{key}");
        task.lock().unwrap()[key] = Value::Null;
    }
    *session_status.lock().unwrap() = "sleeping";
    vm.refresh().await;
    assert!(vm.state().provisioning.is_none());
    *session_status.lock().unwrap() = "active";

    for status in ["in_progress", "completed", "failed", "cancelled", "sleeping", "needs_attention", "draft"] {
        task.lock().unwrap()["status"] = json!(status);
        vm.refresh().await;
        assert!(vm.state().provisioning.is_none(), "{status}");
    }
    task.lock().unwrap()["status"] = json!("delegated");
    task.lock().unwrap()["executionStep"] = Value::Null;
    vm.refresh().await;
    assert_eq!(vm.state().provisioning.unwrap().step, ProvisioningStep::Waiting);
    task.lock().unwrap()["executionStep"] = json!("future_step");
    vm.refresh().await;
    assert_eq!(vm.state().provisioning.unwrap().stage, 0);
    task.lock().unwrap()["executionStep"] = json!("running");
    vm.refresh().await;
    assert!(vm.state().provisioning.is_none());
    vm.load("p1".into(), "missing".into()).await;
    assert!(vm.state().provisioning.is_none());
    assert!(vm.state().items.is_empty());
}
