use conch_sync::{db, router, AppState};
use std::net::SocketAddr;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let path = std::env::var("CONCH_DB").unwrap_or_else(|_| "/data/conch-sync.db".into());
    let listen: SocketAddr = std::env::var("CONCH_LISTEN")
        .unwrap_or_else(|_| "0.0.0.0:8080".into())
        .parse()
        .expect("CONCH_LISTEN");
    let registration = std::env::var("CONCH_REGISTRATION_TOKEN")
        .ok()
        .filter(|s| !s.is_empty());
    let trust_proxy = std::env::var("CONCH_TRUST_PROXY")
        .map(|v| v == "1")
        .unwrap_or(false);
    if registration.is_none() {
        tracing::warn!(
            "CONCH_REGISTRATION_TOKEN not set: anyone who can reach this server can create a vault"
        );
    }

    let conn = db::open(&path).expect("open database");
    let app = router(AppState::new(conn, registration, trust_proxy));
    let listener = tokio::net::TcpListener::bind(listen).await.expect("bind");
    tracing::info!("listening on {listen}, database {path}");
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async {
        // docker stop sends SIGTERM; Ctrl-C for local runs.
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
