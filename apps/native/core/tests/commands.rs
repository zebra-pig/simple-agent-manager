mod common;

use common::{serve, MemoryStore};
use sam_core::{App, CommandsViewModel, Credentials};
use std::sync::Arc;

#[tokio::test]
async fn authenticated_cache_discovery_and_unavailable_cache_fallback() {
    let server = serve(Arc::new(|r| {
        assert_eq!(r.header("cookie").as_deref(), Some("session=fixture"));
        if r.path == "/api/projects/p1/cached-commands" {
            (200, r#"{"commands":[{"agentType":"codex","name":"do","description":"Run the project workflow","updatedAt":1},{"agentType":"codex","name":"review","description":"Custom review"}]}"#.into())
        } else {
            (503, r#"{"message":"Unavailable"}"#.into())
        }
    })).await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=fixture".into() });
    let model = CommandsViewModel::new(App::new(Box::new(store), None));
    model.load("p1".into()).await;
    let state = model.state();
    assert!(state.commands.iter().any(|c| c.name == "do"));
    assert_eq!(state.commands.iter().find(|c| c.name == "review").unwrap().description, "Custom review");
    model.load("p2".into()).await;
    let state = model.state();
    assert_eq!(state.project_id, "p2");
    assert!(!state.commands.iter().any(|c| c.name == "do"), "No commands leak across projects");
    assert!(state.commands.iter().any(|c| c.name == "compact"), "Registry survives an unavailable cache");
}
