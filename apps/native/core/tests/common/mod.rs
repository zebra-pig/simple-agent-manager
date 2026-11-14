//! A scripted stand-in for the SAM API (one request per connection) and an
//! in-memory credential store, shared by the integration tests.

#![allow(dead_code)] // each test binary uses its own subset

use std::sync::{Arc, Mutex};

use sam_core::{CredentialStore, Credentials};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Clones share one slot, so the test can look at what the app saved.
#[derive(Default, Clone)]
pub struct MemoryStore(pub Arc<Mutex<Option<Credentials>>>);

impl CredentialStore for MemoryStore {
    fn load(&self) -> Option<Credentials> {
        self.0.lock().unwrap().clone()
    }
    fn save(&self, credentials: Credentials) {
        *self.0.lock().unwrap() = Some(credentials);
    }
    fn clear(&self) {
        *self.0.lock().unwrap() = None;
    }
}

pub struct Request {
    pub method: String,
    pub path: String,
    /// The raw header block, request line included.
    pub head: String,
    pub body: Vec<u8>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<String> {
        self.head.lines().skip(1).find_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.trim().eq_ignore_ascii_case(name).then(|| v.trim().to_owned())
        })
    }
}

pub type Route = Arc<dyn Fn(&Request) -> (u16, String) + Send + Sync>;

/// Serves `route` on localhost; returns the origin (`http://localhost:port`).
pub async fn serve(route: Route) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let route = route.clone();
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut chunk = [0u8; 16384];
                // Headers, then Content-Length bytes of body.
                let (head, body_len, head_end) = loop {
                    let n = socket.read(&mut chunk).await.unwrap();
                    if n == 0 {
                        return;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&buf[..i]).to_string();
                        let len = head
                            .lines()
                            .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse().unwrap()))
                            .unwrap_or(0usize);
                        break (head, len, i + 4);
                    }
                };
                while buf.len() < head_end + body_len {
                    let n = socket.read(&mut chunk).await.unwrap();
                    buf.extend_from_slice(&chunk[..n]);
                }
                let mut first = head.lines().next().unwrap().split(' ');
                let (method, path) = (first.next().unwrap().to_owned(), first.next().unwrap().to_owned());
                let request = Request { method, path, head, body: buf[head_end..head_end + body_len].to_vec() };
                let (status, body) = route(&request);
                let res = format!(
                    "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket.write_all(res.as_bytes()).await.unwrap();
            });
        }
    });
    format!("http://localhost:{}", addr.port())
}
