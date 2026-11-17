mod common;
use common::{serve, MemoryStore};
use sam_core::{App, Credentials, PortsViewModel};
use serde_json::json;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

#[tokio::test]
async fn private_browser_grant_and_workspace_visibility_use_native_auth() {
    let public = Arc::new(AtomicBool::new(false));
    let forbidden = Arc::new(AtomicBool::new(false));
    let server = serve(Arc::new({
        let public = public.clone();
        let forbidden = forbidden.clone();
        move |r| {
            assert_eq!(r.header("cookie").as_deref(), Some("session=abc"));
            assert_eq!(r.header("accept").as_deref(), Some("application/json"));
            let body = match r.path.as_str() {
                "/api/workspaces/w" => json!({"portsPublicEnabled":public.load(Ordering::SeqCst)}),
                "/api/workspaces/w/ports" => json!({"ports":[
                    {"port":3000,"label":"Web","url":"https://ws-w--3000.localhost/path?port_token=never-share#fragment"},
                    {"port":9000,"label":"Unsafe","url":"https://other.example/"}
                ]}),
                "/api/workspaces/w/port-access?port=3000" => {
                    json!({"url":"https://ws-w--3000.localhost/?port_token=private-grant"})
                }
                "/api/workspaces/w/ports-public" => {
                    assert_eq!(r.method, "PATCH");
                    if forbidden.load(Ordering::SeqCst) {
                        return (403, json!({"message":"Not allowed","error":"Forbidden"}).to_string());
                    }
                    let enabled = serde_json::from_slice::<serde_json::Value>(&r.body).unwrap()["enabled"].as_bool().unwrap();
                    public.store(enabled, Ordering::SeqCst);
                    json!({"portsPublicEnabled":enabled})
                }
                _ => return (404, "{}".into()),
            };
            (200, body.to_string())
        }
    }))
    .await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let vm = PortsViewModel::new(App::new(Box::new(store), None));
    vm.load("w".into());
    vm.refresh().await;
    assert!(vm.state().loaded);
    assert!(!vm.state().public_enabled);
    assert_eq!(vm.state().ports.len(), 1);
    assert_eq!(vm.state().readiness, "ready");
    let grant = vm.open_port(3000).await.unwrap();
    assert!(grant.contains("port_token=private-grant"));
    assert!(!format!("{:?}", vm.state()).contains("private-grant"));
    assert!(vm.open_port(9000).await.is_none());
    vm.set_public(true).await;
    assert!(vm.state().public_enabled);
    assert_eq!(vm.state().ports[0].url, "https://ws-w--3000.localhost/");
    forbidden.store(true, Ordering::SeqCst);
    vm.set_public(false).await;
    assert!(vm.state().public_enabled); // rejection preserves authoritative visibility
    assert!(vm.state().error.is_some());
    forbidden.store(false, Ordering::SeqCst);
    vm.set_public(false).await;
    assert!(!vm.state().public_enabled);
}

#[tokio::test]
async fn sleeping_workspace_shows_lifecycle_and_rejects_foreign_grants() {
    let awake = Arc::new(AtomicBool::new(false));
    let server = serve(Arc::new({
        let awake = awake.clone();
        move |r| {
            let body = match r.path.as_str() {
                "/api/workspaces/w" => json!({"portsPublicEnabled":false}),
                "/api/workspaces/w/ports" if !awake.load(Ordering::SeqCst) => {
                    return (202, json!({"state":"sleeping","ports":[]}).to_string())
                }
                "/api/workspaces/w/ports" => {
                    json!({"ports":[{"port":3000,"label":"Web","url":"https://ws-w--3000.localhost/"}]})
                }
                "/api/workspaces/w/port-access?port=3000" => {
                    json!({"url":"https://attacker.example/?port_token=secret"})
                }
                _ => return (404, "{}".into()),
            };
            (200, body.to_string())
        }
    }))
    .await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let vm = PortsViewModel::new(App::new(Box::new(store), None));
    vm.load("w".into());
    vm.refresh().await;
    assert_eq!(vm.state().readiness, "sleeping");
    awake.store(true, Ordering::SeqCst);
    vm.refresh().await;
    assert!(vm.open_port(3000).await.is_none());
    assert!(vm.state().error.is_some());
    assert!(!format!("{:?}", vm.state()).contains("secret"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn reopening_same_workspace_discards_the_previous_refresh() {
    let started = Arc::new(AtomicBool::new(false));
    let server = serve(Arc::new({
        let started = started.clone();
        move |r| {
            if r.path == "/api/workspaces/w" {
                started.store(true, Ordering::SeqCst);
                std::thread::sleep(std::time::Duration::from_millis(100));
                (200, json!({"portsPublicEnabled":true}).to_string())
            } else {
                (200, json!({"ports":[]}).to_string())
            }
        }
    }))
    .await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: server, session_cookie: "session=abc".into() });
    let vm = PortsViewModel::new(App::new(Box::new(store), None));
    vm.load("w".into());
    let pending = tokio::spawn({
        let vm = vm.clone();
        async move { vm.refresh().await }
    });
    while !started.load(Ordering::SeqCst) {
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    vm.load("w".into());
    pending.await.unwrap();
    assert!(!vm.state().loaded);
    assert!(!vm.state().public_enabled);
}
