mod common;
use common::{serve, MemoryStore};
use sam_core::{App, Credentials, ProjectDraft, ProjectManagementViewModel, UserError};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

type Log = Arc<Mutex<Vec<(String, String, Value)>>>;
async fn setup(log: Log) -> Arc<ProjectManagementViewModel> {
    let server = serve(Arc::new(move |r| {
        assert_eq!(r.header("cookie").as_deref(), Some("session=test"));
        let body: Value = serde_json::from_slice(&r.body).unwrap_or(Value::Null);
        log.lock().unwrap().push((r.method.clone(), r.path.clone(), body.clone()));
        let value = match (r.method.as_str(), r.path.as_str()) {
            ("GET", "/api/github/installations") => json!([{"id":"installation/db","accountName":"Team"}]),
            ("GET", "/api/config/artifacts-enabled") => json!({"enabled":true}),
            ("GET", "/api/github/repositories?installation_id=installation%2Fdb") => json!({"repositories":[{"id":42,"fullName":"team/app","defaultBranch":"develop"}]}),
            ("GET", "/api/github/repositories?installation_id=revoked") => json!({"repositories":[],"failedInstallations":["Team"]}),
            ("GET", "/api/gitlab/projects?search=team+app") => json!({"projects":[{"id":7,"pathWithNamespace":"team/app","defaultBranch":"main"}]}),
            ("GET", "/api/projects/p%2F1") => json!({"id":"p/1","name":"Original","description":"Notes","repository":"team/app","defaultBranch":"develop","repoProvider":"github"}),
            ("POST", "/api/projects") | ("PATCH", "/api/projects/p%2F1") => {
                if body["name"] == "Denied" { return (403, json!({"error":"FORBIDDEN","message":"Owner access required"}).to_string()); }
                json!({"id":"p/1","name":body["name"],"repository":"team/app"})
            }
            ("DELETE", "/api/projects/p%2F1") => json!({"success":true}),
            other => panic!("unexpected {other:?}"),
        };
        (200, value.to_string())
    })).await;
    let store = MemoryStore::default();
    store.0.lock().unwrap().replace(Credentials { server_url: server, session_cookie: "session=test".into() });
    ProjectManagementViewModel::new(App::new(Box::new(store), None))
}
fn draft(provider: &str) -> ProjectDraft {
    ProjectDraft {
        name: " New project ".into(),
        description: " Notes ".into(),
        provider: provider.into(),
        installation_id: "installation/db".into(),
        repository_id: Some(42),
        repository: "team/app".into(),
        default_branch: "develop".into(),
    }
}
#[tokio::test]
async fn creates_all_three_repository_providers_with_web_contracts() {
    let log = Log::default();
    let vm = setup(log.clone()).await;
    vm.load(None).await;
    assert!(vm.state().artifacts_enabled);
    assert_eq!(vm.state().installations[0].id, "installation/db");
    vm.load_repositories("github".into(), "installation/db".into(), "".into()).await;
    assert_eq!(vm.state().repositories[0].default_branch, "develop");
    assert!(vm.save(draft("github")).await.is_some());
    vm.load_repositories("gitlab".into(), "".into(), "team app".into()).await;
    assert_eq!(vm.state().repositories[0].full_name, "team/app");
    assert!(vm.save(draft("gitlab")).await.is_some());
    assert!(vm.save(draft("artifacts")).await.is_some());
    let log = log.lock().unwrap();
    let bodies: Vec<_> = log.iter().filter(|r| r.0 == "POST").map(|r| &r.2).collect();
    assert_eq!(
        bodies[0],
        &json!({"name":"New project","description":"Notes","defaultBranch":"develop","repoProvider":"github","installationId":"installation/db","repository":"team/app","githubRepoId":42})
    );
    assert_eq!(bodies[1]["gitlabProjectId"], 42);
    assert!(bodies[1].get("installationId").is_none());
    assert_eq!(bodies[2]["defaultBranch"], "main");
    assert!(bodies[2].get("repository").is_none());
}
#[tokio::test]
async fn updates_only_general_fields_and_requires_exact_delete_confirmation() {
    let log = Log::default();
    let vm = setup(log.clone()).await;
    vm.load(Some("p/1".into())).await;
    assert_eq!(vm.state().project.unwrap().name, "Original");
    assert!(!vm.delete("original".into()).await);
    assert!(!vm.delete("".into()).await);
    let mut edit = draft("github");
    edit.name = "Renamed".into();
    assert!(vm.save(edit).await.is_some());
    {
        let rows = log.lock().unwrap();
        let patch = rows.iter().find(|r| r.0 == "PATCH").unwrap();
        assert_eq!(patch.2, json!({"name":"Renamed","description":"Notes","defaultBranch":"develop"}));
        assert!(!rows.iter().any(|r| r.0 == "DELETE"));
    }
    assert!(vm.delete("Original".into()).await);
}
#[tokio::test]
async fn failed_mutations_keep_editor_data_and_show_server_error() {
    let vm = setup(Log::default()).await;
    vm.load(Some("p/1".into())).await;
    let mut edit = draft("github");
    edit.name = "Denied".into();
    assert!(vm.save(edit).await.is_none());
    assert!(!vm.state().saving);
    assert_eq!(vm.state().project.unwrap().name, "Original");
    assert!(matches!(vm.state().error, Some(UserError::Server { .. })));
}
#[tokio::test]
async fn invalid_creation_never_posts() {
    let log = Log::default();
    let vm = setup(log.clone()).await;
    vm.load(None).await;
    let mut d = draft("github");
    d.name = " ".into();
    assert!(vm.save(d).await.is_none());
    let mut d = draft("github");
    d.installation_id.clear();
    assert!(vm.save(d).await.is_none());
    let mut d = draft("gitlab");
    d.repository_id = None;
    assert!(vm.save(d).await.is_none());
    assert!(vm.save(draft("unknown")).await.is_none());
    assert!(!log.lock().unwrap().iter().any(|r| r.0 == "POST"));
}
#[tokio::test]
async fn partial_repository_failure_is_actionable_and_clears_on_retry() {
    let vm = setup(Log::default()).await;
    vm.load(None).await;
    vm.load_repositories("github".into(), "revoked".into(), "".into()).await;
    assert_eq!(vm.state().error, Some(UserError::RepositoryAccessFailed));
    vm.load_repositories("github".into(), "installation/db".into(), "".into()).await;
    assert!(vm.state().error.is_none());
    assert_eq!(vm.state().repositories.len(), 1);
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn repository_requests_are_serialized_and_cannot_save_while_loading() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let count = Arc::new(AtomicUsize::new(0));
    let seen = count.clone();
    let server = serve(Arc::new(move |r| {
        assert_eq!(r.path, "/api/github/repositories?installation_id=first");
        seen.fetch_add(1, Ordering::SeqCst);
        std::thread::sleep(std::time::Duration::from_millis(80));
        (200, json!({"repositories":[{"id":1,"fullName":"first/repo","defaultBranch":"main"}]}).to_string())
    }))
    .await;
    let store = MemoryStore::default();
    store.0.lock().unwrap().replace(Credentials { server_url: server, session_cookie: "session=test".into() });
    let vm = ProjectManagementViewModel::new(App::new(Box::new(store), None));
    let first = vm.clone();
    let task = tokio::spawn(async move {
        first.load_repositories("github".into(), "first".into(), "".into()).await;
    });
    while !vm.state().loading {
        tokio::task::yield_now().await;
    }
    vm.load_repositories("github".into(), "second".into(), "".into()).await;
    vm.load(Some("other-project".into())).await;
    assert!(vm.save(draft("github")).await.is_none());
    task.await.unwrap();
    assert_eq!(count.load(Ordering::SeqCst), 1);
    assert_eq!(vm.state().repositories[0].full_name, "first/repo");
    assert!(!vm.state().loading);
}
