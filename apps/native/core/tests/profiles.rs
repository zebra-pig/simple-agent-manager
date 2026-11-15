//! Choosing and editing agent profiles on the project screen, against a
//! scripted stand-in for the SAM API.

mod common;

use std::sync::{Arc, Mutex};

use common::{serve, MemoryStore, Request};
use sam_core::{profile_draft, App, Credentials, ProjectViewModel, UserError};
use serde_json::{json, Value};

/// Every request the app made: (method, path, body).
type Log = Arc<Mutex<Vec<(String, String, Value)>>>;

fn profile(id: &str, project: Option<&str>, name: &str) -> Value {
    json!({"id": id, "projectId": project, "userId": "u1", "name": name, "description": null,
           "agentType": "claude-code", "model": null, "effort": "auto", "permissionMode": null,
           "systemPromptAppend": null, "taskMode": null, "isBuiltin": false, "vmSizeOverride": null})
}

async fn project(log: Log) -> Arc<ProjectViewModel> {
    // The profiles the server holds; POST adds, PUT renames, DELETE removes.
    let profiles = Arc::new(Mutex::new(vec![
        profile("pa", Some("p1"), "Chat"),
        profile("pb", Some("p1"), "Builder"),
        profile("pg", None, "Mine everywhere"),
        profile("ph", Some("p1"), "Hidden"),
    ]));
    let server = serve(Arc::new(move |r: &Request| {
        let body: Value = serde_json::from_slice(&r.body).unwrap_or(Value::Null);
        log.lock().unwrap().push((r.method.clone(), r.path.clone(), body.clone()));
        let mut profiles = profiles.lock().unwrap();
        match (r.method.as_str(), r.path.as_str()) {
            ("GET", "/api/projects/p1/sessions?limit=50") => (200, r#"{"sessions":[]}"#.into()),
            ("GET", "/api/projects/p1/agent-profiles") => (200, json!({"items": *profiles}).to_string()),
            ("GET", "/api/projects/p1/agent-profiles/picker") => (
                200,
                json!({"usage": [{"profileId": "pb", "lastUsedAt": "2026-11-14T00:00:00Z", "chatCount": 3}],
                       "hiddenProfileIds": ["ph"], "usageWindowDays": 30})
                .to_string(),
            ),
            ("GET", "/api/agents") => (
                200,
                json!({"agents": [{"id": "claude-code", "name": "Claude Code", "configured": true, "supportsAcp": true}]}).to_string(),
            ),
            ("POST", "/api/projects/p1/agent-profiles") => {
                if profiles.iter().any(|p| p["name"] == body["name"]) {
                    return (409, json!({"error": "CONFLICT", "message": "Profile already exists"}).to_string());
                }
                let mut created = profile("pn", Some("p1"), body["name"].as_str().unwrap());
                created["effort"] = body["effort"].clone();
                profiles.push(created.clone());
                (201, created.to_string())
            }
            ("PUT", "/api/projects/p1/agent-profiles/pa") => {
                let p = profiles.iter_mut().find(|p| p["id"] == "pa").unwrap();
                p["name"] = body["name"].clone();
                p["model"] = body["model"].clone();
                (200, p.to_string())
            }
            ("DELETE", "/api/projects/p1/agent-profiles/pb") => {
                profiles.retain(|p| p["id"] != "pb");
                (200, r#"{"success":true}"#.into())
            }
            ("POST", "/api/projects/p1/tasks/submit") => {
                (202, r#"{"taskId":"t1","sessionId":"s1","branchName":"b","status":"queued"}"#.into())
            }
            _ => (404, r#"{"error":"NOT_FOUND","message":"Not found"}"#.into()),
        }
    }))
    .await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let vm = ProjectViewModel::new(App::new(Box::new(store), None));
    vm.load("p1".into()).await;
    vm
}

fn ids(vm: &ProjectViewModel) -> Vec<String> {
    vm.state().profiles.iter().map(|p| p.id.clone()).collect()
}

#[tokio::test]
async fn a_new_task_runs_with_the_chosen_profile() {
    let log = Log::default();
    let vm = project(log.clone()).await;
    let state = vm.state();
    assert_eq!(state.error, None);
    // Recent first, hidden left out; only this project's profiles are editable.
    assert_eq!(ids(&vm), ["pb", "pa", "pg"]);
    assert_eq!(state.profiles.iter().map(|p| p.editable).collect::<Vec<_>>(), [true, true, false]);
    assert_eq!(state.selected_profile_id.as_deref(), Some("pb"));

    vm.select_profile("nope".into());
    assert_eq!(vm.state().selected_profile_id.as_deref(), Some("pb"));
    vm.select_profile("pg".into());
    assert!(vm.submit_task("Fix the build".into()).await.is_some());

    let submit = log.lock().unwrap().iter().find(|r| r.1.ends_with("/tasks/submit")).unwrap().2.clone();
    assert_eq!(submit, json!({"message": "Fix the build", "agentProfileId": "pg"}));
    // The choice survives the reload after submitting.
    assert_eq!(vm.state().selected_profile_id.as_deref(), Some("pg"));
}

#[tokio::test]
async fn profiles_are_created_edited_and_deleted() {
    let log = Log::default();
    let vm = project(log.clone()).await;

    vm.load_agents().await;
    assert_eq!(vm.state().agents[0].name, "Claude Code");

    // Create: checked locally first, then the server's own refusal is shown.
    let mut draft = profile_draft(None);
    assert!(!vm.save_profile(None, draft.clone()).await);
    assert_eq!(vm.state().profile_error, Some(UserError::ProfileNameRequired));
    draft.name = "Chat".into();
    assert!(!vm.save_profile(None, draft.clone()).await);
    assert_eq!(vm.state().profile_error, Some(UserError::Server { message: "Profile already exists".into() }));
    draft.name = " Deep work ".into();
    draft.effort = "max".into();
    assert!(vm.save_profile(None, draft).await);
    let state = vm.state();
    assert_eq!(state.profile_error, None);
    assert!(!state.saving_profile);
    assert_eq!(state.selected_profile_id.as_deref(), Some("pn"));
    assert!(ids(&vm).contains(&"pn".to_owned()));

    // Edit: unset fields go out as null so the editor can clear them.
    let pa = vm.state().profiles.into_iter().find(|p| p.id == "pa").unwrap();
    let mut draft = profile_draft(Some(pa));
    draft.name = "Chat (Opus)".into();
    draft.model = "claude-opus-5-5".into();
    assert!(vm.save_profile(Some("pa".into()), draft).await);
    let put = log.lock().unwrap().iter().find(|r| r.0 == "PUT").unwrap().2.clone();
    assert_eq!(
        put,
        json!({"name": "Chat (Opus)", "description": null, "agentType": "claude-code", "model": "claude-opus-5-5",
               "effort": null, "permissionMode": null, "systemPromptAppend": null, "taskMode": null})
    );
    let state = vm.state();
    assert_eq!(state.selected_profile_id.as_deref(), Some("pa"));
    assert_eq!(state.profiles.iter().find(|p| p.id == "pa").unwrap().name, "Chat (Opus)");

    // Delete the selected one: the selection moves to a profile that exists.
    vm.select_profile("pb".into());
    assert!(vm.delete_profile("pb".into()).await);
    assert!(!ids(&vm).contains(&"pb".to_owned()));
    let selected = vm.state().selected_profile_id.unwrap();
    assert!(ids(&vm).contains(&selected));
}
