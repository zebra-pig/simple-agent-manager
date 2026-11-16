mod common;
use common::{serve, MemoryStore, Request};
use sam_core::{App, ChatViewModel, Credentials, DeliveryIntent};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

#[tokio::test]
async fn delivery_modes_capability_and_interrupt_retry() {
    let requests = Arc::new(Mutex::new(Vec::<Value>::new()));
    let captured = requests.clone();
    let supported = Arc::new(Mutex::new(true));
    let capability = supported.clone();
    let cancellations = Arc::new(Mutex::new(0));
    let cancel = cancellations.clone();
    let origin = serve(Arc::new(move |r: &Request| {
        match (r.method.as_str(), r.path.as_str()) {
            ("GET", "/api/projects/p/sessions/s") => (200, json!({
                "session": {"id":"s", "status":"active", "isMine":true, "startedAt":1},
                "state":{"activity":"responding", "steeringSupported": *capability.lock().unwrap()},
                "messages":[{"id":"m", "role":"user", "content":"Correction", "toolMetadata":{"deliveryIntent":"steer", "steerOutcome":"queued_fallback"}}]
            }).to_string()),
            ("POST", "/api/projects/p/sessions/s/prompt") => {
                captured.lock().unwrap().push(serde_json::from_slice(&r.body).unwrap());
                (202, "{}".into())
            }
            ("POST", "/api/projects/p/sessions/s/cancel") => {
                let mut count = cancel.lock().unwrap(); *count += 1;
                if *count == 1 { (503, r#"{"message":"Try again"}"#.into()) }
                else { (200, "{}".into()) }
            }
            _ => (404, "{}".into())
        }
    })).await;
    let store = MemoryStore::default();
    *store.0.lock().unwrap() = Some(Credentials { server_url: origin, session_cookie: "session=fixture".into() });
    let vm = ChatViewModel::new(App::new(Box::new(store), None));
    vm.load("p".into(), "s".into()).await;
    assert!(vm.state().working);
    assert_eq!(vm.state().deliveries[0].status, "queued_instead");
    assert!(vm.send("Use blue".into()).await);
    vm.set_delivery_intent(DeliveryIntent::Queue);
    assert!(vm.send("Then add tests".into()).await);
    vm.set_delivery_intent(DeliveryIntent::Steer);
    *supported.lock().unwrap() = false;
    vm.refresh().await;
    assert!(vm.send("Next".into()).await);
    let intents: Vec<String> = requests.lock().unwrap().iter().map(|v| v["deliveryIntent"].as_str().unwrap().to_string()).collect();
    assert_eq!(intents, ["steer", "queue", "queue"]);
    vm.interrupt().await;
    assert!(vm.state().working && vm.state().interrupt_error.is_some());
    assert!(!vm.state().interrupting);
    let ((), ()) = tokio::join!(vm.interrupt(), vm.interrupt());
    assert_eq!(*cancellations.lock().unwrap(), 2);
    assert!(!vm.state().working);
    assert!(vm.state().interrupt_error.is_none());
    assert_eq!(vm.state().delivery_intent, DeliveryIntent::Steer);
}
