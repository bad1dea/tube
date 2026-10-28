use conch_gateway::{authorize, router, token_hash, AllowRule, Config, Gateway};
use futures_util::{SinkExt, StreamExt};
use std::{collections::HashMap, net::IpAddr, time::Duration};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, Message};

fn ip(s: &str) -> IpAddr {
    s.parse().unwrap()
}

fn rules(s: &[&str]) -> Vec<AllowRule> {
    s.iter().map(|r| AllowRule::parse(r).unwrap()).collect()
}

#[test]
fn policy() {
    let r = rules(&["10.0.0.0/8:22", "*.lan:*", "bastion.example.com:2222"]);
    assert!(authorize(&r, "10.1.2.3", 22, &[ip("10.1.2.3")]).is_ok());
    assert!(authorize(&r, "10.1.2.3", 80, &[ip("10.1.2.3")]).is_err());
    assert!(authorize(&r, "nas.lan", 2022, &[ip("192.168.1.9")]).is_ok());
    assert!(authorize(&r, "bastion.example.com", 2222, &[ip("203.0.113.5")]).is_ok());
    assert!(authorize(&r, "bastion.example.com", 22, &[ip("203.0.113.5")]).is_err());
    assert!(authorize(&r, "evil.com", 22, &[ip("8.8.8.8")]).is_err());
    // A name that resolves into an allowed network is fine.
    assert!(authorize(&r, "db.internal", 22, &[ip("10.9.9.9")]).is_ok());
    // An allowed name pointed at loopback or metadata by DNS is refused.
    assert!(authorize(&r, "x.lan", 22, &[ip("127.0.0.1")]).is_err());
    assert!(authorize(&r, "x.lan", 22, &[ip("169.254.169.254")]).is_err());
    // Mixed answers: only the safe address is returned.
    assert_eq!(
        authorize(&r, "x.lan", 22, &[ip("127.0.0.1"), ip("192.168.1.2")]).unwrap(),
        vec![ip("192.168.1.2")]
    );
    // Loopback only when a CIDR rule names it.
    let lo = rules(&["127.0.0.1:2022"]);
    assert!(authorize(&lo, "localhost", 2022, &[ip("127.0.0.1")]).is_ok());
    assert!(authorize(&[], "10.0.0.1", 22, &[ip("10.0.0.1")]).is_err());
}

#[test]
fn rule_parsing() {
    assert!(AllowRule::parse("[fd00::/8]:22").is_ok());
    assert!(AllowRule::parse("10.0.0.1:*").is_ok());
    assert!(AllowRule::parse("host-without-port").is_err());
    assert!(AllowRule::parse("h:notaport").is_err());
}

async fn start(allow: &[&str], origins: Vec<String>) -> String {
    let mut tokens = HashMap::new();
    tokens.insert(token_hash("good-token"), "alice".to_string());
    let gw = Gateway::new(Config {
        tokens,
        allow: rules(allow),
        origins,
        max_sessions_per_user: 2,
        connect_timeout: Duration::from_secs(2),
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(
            listener,
            router(gw).into_make_service_with_connect_info::<std::net::SocketAddr>(),
        )
        .await
        .unwrap()
    });
    format!("ws://{addr}/relay")
}

async fn echo_server() -> u16 {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let (mut s, _) = l.accept().await.unwrap();
            tokio::spawn(async move {
                let mut buf = [0u8; 1024];
                while let Ok(n) = s.read(&mut buf).await {
                    if n == 0 || s.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
            });
        }
    });
    port
}

async fn hello(
    url: &str,
    token: &str,
    port: u16,
) -> (
    String,
    Option<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    >,
) {
    let (mut ws, _) = tokio_tungstenite::connect_async(url).await.unwrap();
    ws.send(Message::Text(
        format!(r#"{{"token":"{token}","host":"127.0.0.1","port":{port}}}"#).into(),
    ))
    .await
    .unwrap();
    match ws.next().await {
        Some(Ok(Message::Text(t))) => (t.to_string(), Some(ws)),
        other => (format!("{other:?}"), None),
    }
}

#[tokio::test]
async fn relays_bytes_both_ways() {
    let port = echo_server().await;
    let url = start(&[&format!("127.0.0.1:{port}")], vec![]).await;
    let (reply, ws) = hello(&url, "good-token", port).await;
    assert_eq!(reply, r#"{"ok":true}"#);
    let mut ws = ws.unwrap();
    ws.send(Message::Binary(b"SSH-2.0-test\r\n".to_vec().into()))
        .await
        .unwrap();
    match ws.next().await {
        Some(Ok(Message::Binary(b))) => assert_eq!(&b[..], b"SSH-2.0-test\r\n"),
        other => panic!("{other:?}"),
    }
}

#[tokio::test]
async fn bad_token_is_refused() {
    let port = echo_server().await;
    let url = start(&[&format!("127.0.0.1:{port}")], vec![]).await;
    let (reply, _) = hello(&url, "nope", port).await;
    assert!(reply.contains("invalid token"), "{reply}");
}

#[tokio::test]
async fn destination_outside_policy_is_refused() {
    let port = echo_server().await;
    let url = start(&["10.0.0.0/8:22"], vec![]).await;
    let (reply, _) = hello(&url, "good-token", port).await;
    assert!(reply.contains("not allowed"), "{reply}");
}

#[tokio::test]
async fn session_limit_per_user() {
    let port = echo_server().await;
    let url = start(&[&format!("127.0.0.1:{port}")], vec![]).await;
    let (_, a) = hello(&url, "good-token", port).await;
    let (_, b) = hello(&url, "good-token", port).await;
    let (reply, _) = hello(&url, "good-token", port).await;
    assert!(reply.contains("too many"), "{reply}");
    drop(a);
    drop(b);
}

#[tokio::test]
async fn origin_is_checked() {
    let port = echo_server().await;
    let url = start(
        &[&format!("127.0.0.1:{port}")],
        vec!["https://conch.example".into()],
    )
    .await;
    let mut req = url.clone().into_client_request().unwrap();
    req.headers_mut()
        .insert("origin", "https://evil.example".parse().unwrap());
    assert!(tokio_tungstenite::connect_async(req).await.is_err());
    let mut req = url.into_client_request().unwrap();
    req.headers_mut()
        .insert("origin", "https://conch.example".parse().unwrap());
    assert!(tokio_tungstenite::connect_async(req).await.is_ok());
}
