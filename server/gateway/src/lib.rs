//! WebSocket to TCP relay for the Conch web client.
//!
//! The browser runs SSH itself (Go x/crypto/ssh compiled to WebAssembly) and
//! uses this relay as its socket. The relay sees which host and port a user
//! connects to and how many bytes flow, never credentials or terminal content.

use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        ConnectInfo, State,
    },
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use futures_util::{SinkExt, StreamExt};
use ipnet::IpNet;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};

#[derive(Debug, Clone, PartialEq)]
pub enum HostRule {
    Net(IpNet),
    /// Exact name or `*.suffix`.
    Name(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct AllowRule {
    pub host: HostRule,
    /// None = any port.
    pub port: Option<u16>,
}

impl AllowRule {
    /// `10.0.0.0/8:22`, `192.168.1.5:*`, `[fd00::/8]:22`, `*.lan:22`, `bastion.example.com:2222`
    pub fn parse(s: &str) -> Result<Self, String> {
        let s = s.trim();
        let (host, port) = if let Some(rest) = s.strip_prefix('[') {
            let (h, p) = rest
                .split_once("]:")
                .ok_or_else(|| format!("bad rule {s}"))?;
            (h, p)
        } else {
            s.rsplit_once(':')
                .ok_or_else(|| format!("rule needs :port or :* ({s})"))?
        };
        let port = if port == "*" {
            None
        } else {
            Some(port.parse().map_err(|_| format!("bad port in {s}"))?)
        };
        let host = if let Ok(net) = host.parse::<IpNet>() {
            HostRule::Net(net)
        } else if let Ok(ip) = host.parse::<IpAddr>() {
            HostRule::Net(IpNet::from(ip))
        } else {
            HostRule::Name(host.to_ascii_lowercase())
        };
        Ok(AllowRule { host, port })
    }

    fn port_ok(&self, port: u16) -> bool {
        self.port.is_none_or(|p| p == port)
    }
}

#[derive(Clone)]
pub struct Config {
    /// sha256(token) hex -> user name
    pub tokens: HashMap<String, String>,
    pub allow: Vec<AllowRule>,
    /// Empty = do not check Origin (only for tests and local use).
    pub origins: Vec<String>,
    pub max_sessions_per_user: usize,
    pub connect_timeout: Duration,
}

#[derive(Clone)]
pub struct Gateway {
    pub config: Arc<Config>,
    sessions: Arc<Mutex<HashMap<String, usize>>>,
    attempts: Arc<Mutex<HashMap<IpAddr, (u32, Instant)>>>,
}

impl Gateway {
    pub fn new(config: Config) -> Self {
        Gateway {
            config: Arc::new(config),
            sessions: Arc::default(),
            attempts: Arc::default(),
        }
    }
}

pub fn token_hash(token: &str) -> String {
    Sha256::digest(token.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

pub fn new_token() -> String {
    let mut b = [0u8; 32];
    getrandom::fill(&mut b).expect("system RNG");
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(b)
}

/// Addresses never reachable through the relay unless a rule names them
/// explicitly by CIDR: loopback (the gateway's own services), link-local
/// (cloud metadata at 169.254.169.254), unspecified.
fn sensitive(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_loopback() || v4.is_link_local() || v4.is_unspecified(),
        IpAddr::V6(v6) => {
            v6.is_loopback() || v6.is_unspecified() || (v6.segments()[0] & 0xffc0) == 0xfe80
        }
    }
}

/// Decides whether `host:port` may be dialled and returns the addresses to try.
/// Name rules match the requested name; the resolved address must still not be
/// sensitive. CIDR rules match resolved addresses, so a name that resolves into
/// an allowed network works and DNS cannot point an allowed name at loopback.
pub fn authorize(
    rules: &[AllowRule],
    host: &str,
    port: u16,
    resolved: &[IpAddr],
) -> Result<Vec<IpAddr>, &'static str> {
    let name = host.trim_end_matches('.').to_ascii_lowercase();
    let name_allowed = rules.iter().any(|r| {
        r.port_ok(port)
            && match &r.host {
                HostRule::Name(n) => match n.strip_prefix("*.") {
                    Some(suffix) => name.ends_with(&format!(".{suffix}")),
                    None => *n == name,
                },
                HostRule::Net(_) => false,
            }
    });
    let ok: Vec<IpAddr> = resolved
        .iter()
        .copied()
        .filter(|ip| {
            let by_net = rules
                .iter()
                .any(|r| r.port_ok(port) && matches!(&r.host, HostRule::Net(n) if n.contains(ip)));
            by_net || (name_allowed && !sensitive(*ip))
        })
        .collect();
    if ok.is_empty() {
        Err("destination not allowed by gateway policy")
    } else {
        Ok(ok)
    }
}

pub fn router(gw: Gateway) -> Router {
    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/relay", get(relay))
        .with_state(gw)
}

struct ClientAddr(Option<SocketAddr>);

impl<S: Send + Sync> axum::extract::FromRequestParts<S> for ClientAddr {
    type Rejection = std::convert::Infallible;
    async fn from_request_parts(
        parts: &mut axum::http::request::Parts,
        _: &S,
    ) -> Result<Self, Self::Rejection> {
        Ok(ClientAddr(
            parts
                .extensions
                .get::<ConnectInfo<SocketAddr>>()
                .map(|c| c.0),
        ))
    }
}

async fn relay(
    State(gw): State<Gateway>,
    ClientAddr(addr): ClientAddr,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    if !gw.config.origins.is_empty() {
        let origin = headers
            .get("origin")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        if !gw.config.origins.iter().any(|o| o == origin) {
            return (StatusCode::FORBIDDEN, "origin not allowed").into_response();
        }
    }
    let ip = addr.map(|a| a.ip()).unwrap_or(IpAddr::from([127, 0, 0, 1]));
    {
        let mut attempts = gw.attempts.lock().unwrap();
        let now = Instant::now();
        let e = attempts.entry(ip).or_insert((0, now));
        if now.duration_since(e.1) > Duration::from_secs(60) {
            *e = (0, now);
        }
        e.0 += 1;
        if e.0 > 30 {
            return (StatusCode::TOO_MANY_REQUESTS, "rate limited").into_response();
        }
    }
    ws.max_message_size(1 << 20)
        .on_upgrade(move |socket| handle(gw, socket, ip))
}

#[derive(Deserialize)]
struct Hello {
    token: String,
    host: String,
    port: u16,
}

async fn reply_error(mut socket: WebSocket, msg: &str) {
    let _ = socket
        .send(Message::Text(
            serde_json::json!({ "error": msg }).to_string().into(),
        ))
        .await;
    let _ = socket.close().await;
}

async fn handle(gw: Gateway, mut socket: WebSocket, client: IpAddr) {
    // First frame authenticates and names the destination. Keeping the token
    // out of the URL keeps it out of proxy access logs.
    let hello = match tokio::time::timeout(Duration::from_secs(10), socket.recv()).await {
        Ok(Some(Ok(Message::Text(t)))) => serde_json::from_str::<Hello>(&t).ok(),
        _ => None,
    };
    let Some(hello) = hello else {
        return reply_error(socket, "expected hello").await;
    };
    let Some(user) = gw.config.tokens.get(&token_hash(&hello.token)).cloned() else {
        tracing::warn!(%client, "relay: bad token");
        return reply_error(socket, "invalid token").await;
    };

    let resolved: Vec<IpAddr> =
        match tokio::net::lookup_host((hello.host.as_str(), hello.port)).await {
            Ok(addrs) => addrs.map(|a| a.ip()).collect(),
            Err(_) => return reply_error(socket, "cannot resolve host").await,
        };
    let targets = match authorize(&gw.config.allow, &hello.host, hello.port, &resolved) {
        Ok(t) => t,
        Err(e) => {
            tracing::warn!(%client, %user, host = %hello.host, port = hello.port, "relay: denied");
            return reply_error(socket, e).await;
        }
    };

    let admitted = {
        let mut s = gw.sessions.lock().unwrap();
        let n = s.entry(user.clone()).or_insert(0);
        if *n < gw.config.max_sessions_per_user {
            *n += 1;
            true
        } else {
            false
        }
    };
    if !admitted {
        return reply_error(socket, "too many open sessions").await;
    }
    let _guard = SessionGuard {
        gw: gw.clone(),
        user: user.clone(),
    };

    let mut stream = None;
    for ip in &targets {
        if let Ok(Ok(s)) = tokio::time::timeout(
            gw.config.connect_timeout,
            TcpStream::connect((*ip, hello.port)),
        )
        .await
        {
            stream = Some(s);
            break;
        }
    }
    let Some(stream) = stream else {
        return reply_error(socket, "connection to host failed").await;
    };
    let _ = stream.set_nodelay(true);
    if socket
        .send(Message::Text(r#"{"ok":true}"#.into()))
        .await
        .is_err()
    {
        return;
    }

    let started = Instant::now();
    tracing::info!(%client, %user, host = %hello.host, port = hello.port, "relay: open");
    let (mut tcp_r, mut tcp_w) = stream.into_split();
    let (mut ws_tx, mut ws_rx) = socket.split();

    let up = async {
        let mut n: u64 = 0;
        while let Some(Ok(msg)) = ws_rx.next().await {
            match msg {
                Message::Binary(b) => {
                    n += b.len() as u64;
                    if tcp_w.write_all(&b).await.is_err() {
                        break;
                    }
                }
                Message::Close(_) => break,
                _ => {}
            }
        }
        let _ = tcp_w.shutdown().await;
        n
    };
    let down = async {
        let mut n: u64 = 0;
        let mut buf = vec![0u8; 32 * 1024];
        loop {
            match tcp_r.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(k) => {
                    n += k as u64;
                    if ws_tx
                        .send(Message::Binary(buf[..k].to_vec().into()))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
            }
        }
        let _ = ws_tx.close().await;
        n
    };
    // Either side closing ends the session.
    let (bytes_up, bytes_down) = tokio::select! {
        u = up => (u, 0),
        d = down => (0, d),
    };
    tracing::info!(
        %client, %user, host = %hello.host, port = hello.port,
        secs = started.elapsed().as_secs(), bytes_up, bytes_down,
        "relay: closed"
    );
}

struct SessionGuard {
    gw: Gateway,
    user: String,
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        if let Some(n) = self.gw.sessions.lock().unwrap().get_mut(&self.user) {
            *n = n.saturating_sub(1);
        }
    }
}
