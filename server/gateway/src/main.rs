use std::{collections::HashMap, net::SocketAddr, time::Duration};
use tube_gateway::{new_token, router, token_hash, AllowRule, Config, Gateway};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("token") {
        let name = args.get(2).cloned().unwrap_or_else(|| "user".into());
        let token = new_token();
        println!("token for the web client:  {token}");
        println!("add to TUBE_GATEWAY_TOKENS: {name}:{}", token_hash(&token));
        return;
    }
    tokio::runtime::Runtime::new().unwrap().block_on(serve());
}

async fn serve() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let env = |k: &str| std::env::var(k).unwrap_or_default();
    let tokens: HashMap<String, String> = env("TUBE_GATEWAY_TOKENS")
        .split(',')
        .filter_map(|e| e.trim().split_once(':'))
        .map(|(name, hash)| (hash.to_ascii_lowercase(), name.to_string()))
        .collect();
    let allow: Vec<AllowRule> = env("TUBE_GATEWAY_ALLOW")
        .split(',')
        .filter(|s| !s.trim().is_empty())
        .map(|s| AllowRule::parse(s).unwrap_or_else(|e| panic!("TUBE_GATEWAY_ALLOW: {e}")))
        .collect();
    let origins: Vec<String> = env("TUBE_GATEWAY_ORIGINS")
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    if tokens.is_empty() {
        tracing::warn!("TUBE_GATEWAY_TOKENS is empty: every connection will be refused");
    }
    if allow.is_empty() {
        tracing::warn!("TUBE_GATEWAY_ALLOW is empty: no destination is reachable");
    }
    if origins.is_empty() {
        tracing::warn!("TUBE_GATEWAY_ORIGINS is empty: Origin header is not checked");
    }
    let config = Config {
        tokens,
        allow,
        origins,
        max_sessions_per_user: env("TUBE_GATEWAY_MAX_SESSIONS").parse().unwrap_or(8),
        connect_timeout: Duration::from_secs(10),
    };
    let listen: SocketAddr = std::env::var("TUBE_LISTEN")
        .unwrap_or_else(|_| "0.0.0.0:8081".into())
        .parse()
        .expect("TUBE_LISTEN");
    let listener = tokio::net::TcpListener::bind(listen).await.expect("bind");
    tracing::info!("gateway listening on {listen}");
    axum::serve(
        listener,
        router(Gateway::new(config)).into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = term.recv() => {}
        }
    })
    .await
    .unwrap();
}
