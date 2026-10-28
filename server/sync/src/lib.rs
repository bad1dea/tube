//! Conch sync server. Holds wrapped vault keys and AES-GCM record ciphertext;
//! it never sees a vault key or plaintext. See docs/sync-protocol.md.

pub mod db;

use axum::{
    extract::{ConnectInfo, DefaultBodyLimit, FromRequestParts, Path, Query, State},
    http::{request::Parts, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
    Json, Router,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

pub const MAX_RECORD_BYTES: usize = 256 * 1024;
pub const MAX_BATCH: usize = 500;
pub const INVITE_TTL_SECS: i64 = 600;

#[derive(Clone)]
pub struct AppState {
    pub db: Arc<Mutex<Connection>>,
    /// Browser origins allowed to call the API (the web client). Empty = none.
    pub cors_origins: Vec<String>,
    pub registration_token: Option<String>,
    pub trust_proxy: bool,
    pub limiter: Arc<Limiter>,
}

impl AppState {
    pub fn new(conn: Connection, registration_token: Option<String>, trust_proxy: bool) -> Self {
        AppState {
            db: Arc::new(Mutex::new(conn)),
            cors_origins: vec![],
            registration_token,
            trust_proxy,
            limiter: Arc::new(Limiter::new(10, Duration::from_secs(60))),
        }
    }
}

pub fn router(state: AppState) -> Router {
    use axum::http::{header, HeaderValue, Method};
    use tower_http::cors::{AllowOrigin, CorsLayer};
    let origins: Vec<HeaderValue> = state
        .cors_origins
        .iter()
        .filter_map(|o| o.parse().ok())
        .collect();
    let cors = CorsLayer::new()
        .allow_origin(AllowOrigin::list(origins))
        .allow_methods([Method::GET, Method::POST, Method::PUT, Method::DELETE])
        .allow_headers([
            header::AUTHORIZATION,
            header::CONTENT_TYPE,
            header::HeaderName::from_static("x-conch-registration"),
        ]);
    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/v1/vaults", post(create_vault))
        .route("/v1/vault", get(get_vault))
        .route("/v1/vault/key", put(rotate_key))
        .route("/v1/records", get(pull).post(push))
        .route("/v1/devices", get(list_devices))
        .route("/v1/devices/{id}", delete(revoke_device))
        .route("/v1/pairing", post(create_invite))
        .route("/v1/pairing/{id}/claim", post(claim_invite))
        .route("/v1/recover", post(recover))
        .layer(DefaultBodyLimit::max(MAX_BATCH * MAX_RECORD_BYTES / 8))
        .layer(cors)
        .with_state(state)
}

// ---------------------------------------------------------------- errors

pub struct ApiError(StatusCode, &'static str);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(serde_json::json!({ "error": self.1 }))).into_response()
    }
}

impl From<rusqlite::Error> for ApiError {
    fn from(e: rusqlite::Error) -> Self {
        tracing::error!("database: {e}");
        ApiError(StatusCode::INTERNAL_SERVER_ERROR, "database error")
    }
}

type ApiResult<T> = Result<T, ApiError>;

fn bad(msg: &'static str) -> ApiError {
    ApiError(StatusCode::BAD_REQUEST, msg)
}

// ---------------------------------------------------------------- helpers

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

fn random_token(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    getrandom::fill(&mut buf).expect("system RNG");
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(buf)
}

fn sha256(data: &[u8]) -> Vec<u8> {
    Sha256::digest(data).to_vec()
}

fn decode_b64(s: &str, max: usize) -> ApiResult<Vec<u8>> {
    let v = B64.decode(s).map_err(|_| bad("invalid base64"))?;
    if v.len() > max {
        return Err(ApiError(StatusCode::PAYLOAD_TOO_LARGE, "value too large"));
    }
    Ok(v)
}

fn valid_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn valid_kind(s: &str) -> bool {
    !s.is_empty() && s.len() <= 32 && s.chars().all(|c| c.is_ascii_lowercase() || c == '_')
}

/// Constant-time equality for secrets compared in memory.
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn issue_device(conn: &Connection, vault: &str, name: &str) -> rusqlite::Result<(String, String)> {
    let id = random_token(12);
    let secret = random_token(32);
    let token = format!("{id}.{secret}");
    let t = now();
    conn.execute(
        "INSERT INTO devices (id, vault_id, name, token_hash, created_at, last_seen) VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
        params![id, vault, name, sha256(token.as_bytes()), t],
    )?;
    Ok((id, token))
}

fn device_name(s: &str) -> String {
    s.chars().filter(|c| !c.is_control()).take(64).collect()
}

// ---------------------------------------------------------------- rate limit

/// Fixed-window counter for unauthenticated endpoints, keyed by client address
/// and route. In-memory only: a restart resets it.
pub struct Limiter {
    max: u32,
    window: Duration,
    hits: Mutex<HashMap<String, (u32, Instant)>>,
}

impl Limiter {
    pub fn new(max: u32, window: Duration) -> Self {
        Limiter {
            max,
            window,
            hits: Mutex::new(HashMap::new()),
        }
    }

    pub fn check(&self, key: String) -> ApiResult<()> {
        let mut hits = self.hits.lock().unwrap();
        let now = Instant::now();
        if hits.len() > 10_000 {
            hits.retain(|_, (_, start)| now.duration_since(*start) < self.window);
        }
        let entry = hits.entry(key).or_insert((0, now));
        if now.duration_since(entry.1) >= self.window {
            *entry = (0, now);
        }
        entry.0 += 1;
        if entry.0 > self.max {
            return Err(ApiError(StatusCode::TOO_MANY_REQUESTS, "rate limited"));
        }
        Ok(())
    }
}

fn client_key(state: &AppState, headers: &HeaderMap, addr: Option<SocketAddr>) -> String {
    if state.trust_proxy {
        if let Some(xff) = headers.get("x-forwarded-for").and_then(|v| v.to_str().ok()) {
            if let Some(first) = xff.split(',').next() {
                return first.trim().to_string();
            }
        }
    }
    addr.map(|a| a.ip().to_string())
        .unwrap_or_else(|| "local".into())
}

// ---------------------------------------------------------------- auth

/// Peer address when served with connect info; None under test harnesses.
pub struct ClientAddr(pub Option<SocketAddr>);

impl<S: Send + Sync> FromRequestParts<S> for ClientAddr {
    type Rejection = std::convert::Infallible;

    async fn from_request_parts(parts: &mut Parts, _: &S) -> Result<Self, Self::Rejection> {
        Ok(ClientAddr(
            parts
                .extensions
                .get::<ConnectInfo<SocketAddr>>()
                .map(|c| c.0),
        ))
    }
}

pub struct AuthDevice {
    pub id: String,
    pub vault_id: String,
}

impl FromRequestParts<AppState> for AuthDevice {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let token = parts
            .headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .ok_or(ApiError(StatusCode::UNAUTHORIZED, "missing token"))?;
        let conn = state.db.lock().unwrap();
        let dev = db::device_by_token_hash(&conn, &sha256(token.as_bytes()))?.ok_or(ApiError(
            StatusCode::UNAUTHORIZED,
            "invalid or revoked token",
        ))?;
        conn.execute(
            "UPDATE devices SET last_seen = ?1 WHERE id = ?2",
            params![now(), dev.id],
        )?;
        Ok(AuthDevice {
            id: dev.id,
            vault_id: dev.vault_id,
        })
    }
}

// ---------------------------------------------------------------- vaults

#[derive(Deserialize)]
pub struct CreateVault {
    pub vault_id: String,
    pub wrapped_key: String,
    pub recovery_auth: String,
    pub device_name: String,
}

#[derive(Serialize, Deserialize)]
pub struct DeviceToken {
    pub vault_id: String,
    pub device_id: String,
    pub token: String,
}

async fn create_vault(
    State(state): State<AppState>,
    ClientAddr(addr): ClientAddr,
    headers: HeaderMap,
    Json(req): Json<CreateVault>,
) -> ApiResult<(StatusCode, Json<DeviceToken>)> {
    state
        .limiter
        .check(format!("create|{}", client_key(&state, &headers, addr)))?;
    if let Some(expected) = &state.registration_token {
        let given = headers
            .get("x-conch-registration")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        if !ct_eq(given.as_bytes(), expected.as_bytes()) {
            return Err(ApiError(
                StatusCode::FORBIDDEN,
                "registration token required",
            ));
        }
    }
    if !valid_id(&req.vault_id) {
        return Err(bad("invalid vault id"));
    }
    let wrapped = decode_b64(&req.wrapped_key, 1024)?;
    let auth = decode_b64(&req.recovery_auth, 64)?;
    if auth.len() != 32 {
        return Err(bad("recovery_auth must be 32 bytes"));
    }
    let conn = state.db.lock().unwrap();
    let inserted = conn.execute(
        "INSERT OR IGNORE INTO vaults (id, wrapped_key, recovery_auth_hash, created_at) VALUES (?1, ?2, ?3, ?4)",
        params![req.vault_id, wrapped, sha256(&auth), now()],
    )?;
    if inserted == 0 {
        return Err(ApiError(StatusCode::CONFLICT, "vault exists"));
    }
    let (device_id, token) = issue_device(&conn, &req.vault_id, &device_name(&req.device_name))?;
    tracing::info!(vault = %req.vault_id, device = %device_id, "vault created");
    Ok((
        StatusCode::CREATED,
        Json(DeviceToken {
            vault_id: req.vault_id,
            device_id,
            token,
        }),
    ))
}

#[derive(Serialize, Deserialize)]
pub struct VaultInfo {
    pub vault_id: String,
    pub key_epoch: i64,
    pub wrapped_key: String,
    pub device_id: String,
}

async fn get_vault(State(state): State<AppState>, dev: AuthDevice) -> ApiResult<Json<VaultInfo>> {
    let conn = state.db.lock().unwrap();
    let (wrapped, epoch): (Vec<u8>, i64) = conn.query_row(
        "SELECT wrapped_key, key_epoch FROM vaults WHERE id = ?1",
        params![dev.vault_id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    Ok(Json(VaultInfo {
        vault_id: dev.vault_id,
        key_epoch: epoch,
        wrapped_key: B64.encode(wrapped),
        device_id: dev.id,
    }))
}

#[derive(Deserialize)]
pub struct RotateKey {
    pub wrapped_key: String,
    /// Must be current epoch + 1; prevents two devices rotating at once.
    pub key_epoch: i64,
}

async fn rotate_key(
    State(state): State<AppState>,
    dev: AuthDevice,
    Json(req): Json<RotateKey>,
) -> ApiResult<StatusCode> {
    let wrapped = decode_b64(&req.wrapped_key, 1024)?;
    let conn = state.db.lock().unwrap();
    let changed = conn.execute(
        "UPDATE vaults SET wrapped_key = ?1, key_epoch = ?2 WHERE id = ?3 AND key_epoch = ?2 - 1",
        params![wrapped, req.key_epoch, dev.vault_id],
    )?;
    if changed == 0 {
        return Err(ApiError(StatusCode::CONFLICT, "key epoch changed"));
    }
    // Old invites carry the previous vault key.
    conn.execute(
        "DELETE FROM invites WHERE vault_id = ?1",
        params![dev.vault_id],
    )?;
    tracing::info!(vault = %dev.vault_id, device = %dev.id, epoch = req.key_epoch, "vault key rotated");
    Ok(StatusCode::NO_CONTENT)
}

// ---------------------------------------------------------------- records

#[derive(Deserialize)]
pub struct PullQuery {
    #[serde(default)]
    pub since: i64,
}

#[derive(Serialize, Deserialize)]
pub struct PullResponse {
    pub records: Vec<db::Record>,
    pub cursor: i64,
    pub more: bool,
}

async fn pull(
    State(state): State<AppState>,
    dev: AuthDevice,
    Query(q): Query<PullQuery>,
) -> ApiResult<Json<PullResponse>> {
    let conn = state.db.lock().unwrap();
    let limit = 1000;
    let records = db::records_since(&conn, &dev.vault_id, q.since, limit)?;
    let cursor = records.last().map(|r| r.seq).unwrap_or(q.since);
    let more = records.len() as i64 == limit;
    Ok(Json(PullResponse {
        records,
        cursor,
        more,
    }))
}

#[derive(Deserialize)]
pub struct PushRecord {
    pub id: String,
    pub kind: String,
    /// Version the client last saw; 0 for a new record.
    pub base_version: i64,
    pub epoch: i64,
    #[serde(default)]
    pub deleted: bool,
    pub ciphertext: Option<String>,
}

#[derive(Deserialize)]
pub struct PushRequest {
    pub records: Vec<PushRecord>,
}

#[derive(Serialize, Deserialize)]
pub struct Applied {
    pub id: String,
    pub version: i64,
    pub seq: i64,
}

#[derive(Serialize, Deserialize)]
pub struct PushResponse {
    pub applied: Vec<Applied>,
    /// Server copies of records whose base_version was stale.
    pub conflicts: Vec<db::Record>,
}

async fn push(
    State(state): State<AppState>,
    dev: AuthDevice,
    Json(req): Json<PushRequest>,
) -> ApiResult<Json<PushResponse>> {
    if req.records.len() > MAX_BATCH {
        return Err(ApiError(StatusCode::PAYLOAD_TOO_LARGE, "too many records"));
    }
    let mut conn = state.db.lock().unwrap();
    let tx = conn.transaction()?;
    let epoch: i64 = tx.query_row(
        "SELECT key_epoch FROM vaults WHERE id = ?1",
        params![dev.vault_id],
        |r| r.get(0),
    )?;
    let mut applied = vec![];
    let mut conflicts = vec![];
    for r in &req.records {
        if !valid_id(&r.id) || !valid_kind(&r.kind) {
            return Err(bad("invalid record id or kind"));
        }
        if r.epoch != epoch {
            return Err(ApiError(StatusCode::CONFLICT, "stale key epoch"));
        }
        let ct = match (&r.ciphertext, r.deleted) {
            (Some(c), false) => Some(decode_b64(c, MAX_RECORD_BYTES)?),
            (_, true) => None,
            (None, false) => return Err(bad("ciphertext required")),
        };
        let current = db::record(&tx, &dev.vault_id, &r.id)?;
        let current_version = current.as_ref().map(|c| c.version).unwrap_or(0);
        if current_version != r.base_version {
            if let Some(c) = current {
                conflicts.push(c);
            }
            continue;
        }
        if let Some(c) = &current {
            if c.kind != r.kind {
                return Err(bad("record kind cannot change"));
            }
        }
        let seq: i64 = tx.query_row(
            "UPDATE vaults SET next_seq = next_seq + 1 WHERE id = ?1 RETURNING next_seq - 1",
            params![dev.vault_id],
            |row| row.get(0),
        )?;
        let version = current_version + 1;
        tx.execute(
            "INSERT INTO records (vault_id, id, kind, version, epoch, deleted, ciphertext, seq, updated_by, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
             ON CONFLICT(vault_id, id) DO UPDATE SET version = excluded.version, epoch = excluded.epoch,
               deleted = excluded.deleted, ciphertext = excluded.ciphertext, seq = excluded.seq,
               updated_by = excluded.updated_by, updated_at = excluded.updated_at",
            params![dev.vault_id, r.id, r.kind, version, r.epoch, r.deleted as i64, ct, seq, dev.id, now()],
        )?;
        applied.push(Applied {
            id: r.id.clone(),
            version,
            seq,
        });
    }
    tx.commit()?;
    Ok(Json(PushResponse { applied, conflicts }))
}

// ---------------------------------------------------------------- devices

#[derive(Serialize, Deserialize)]
pub struct DeviceInfo {
    pub id: String,
    pub name: String,
    pub created_at: i64,
    pub last_seen: i64,
    pub revoked: bool,
    pub current: bool,
}

async fn list_devices(
    State(state): State<AppState>,
    dev: AuthDevice,
) -> ApiResult<Json<Vec<DeviceInfo>>> {
    let conn = state.db.lock().unwrap();
    let mut stmt = conn.prepare(
        "SELECT id, name, created_at, last_seen, revoked_at IS NOT NULL FROM devices WHERE vault_id = ?1 ORDER BY created_at",
    )?;
    let rows = stmt
        .query_map(params![dev.vault_id], |r| {
            let id: String = r.get(0)?;
            Ok(DeviceInfo {
                current: id == dev.id,
                id,
                name: r.get(1)?,
                created_at: r.get(2)?,
                last_seen: r.get(3)?,
                revoked: r.get(4)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(rows))
}

async fn revoke_device(
    State(state): State<AppState>,
    dev: AuthDevice,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let conn = state.db.lock().unwrap();
    let n = conn.execute(
        "UPDATE devices SET revoked_at = ?1 WHERE id = ?2 AND vault_id = ?3 AND revoked_at IS NULL",
        params![now(), id, dev.vault_id],
    )?;
    if n == 0 {
        return Err(ApiError(StatusCode::NOT_FOUND, "no such device"));
    }
    // Invites created by the revoked device would still hand out the vault key.
    conn.execute("DELETE FROM invites WHERE created_by = ?1", params![id])?;
    tracing::info!(vault = %dev.vault_id, by = %dev.id, revoked = %id, "device revoked");
    Ok(StatusCode::NO_CONTENT)
}

// ---------------------------------------------------------------- pairing

#[derive(Deserialize)]
pub struct CreateInvite {
    /// Client-chosen, 128-bit random. Doubles as the HKDF salt for the payload.
    pub invite_id: String,
    /// Vault key sealed under a key derived from a secret the server never sees.
    pub payload: String,
}

#[derive(Serialize, Deserialize)]
pub struct InviteCreated {
    pub invite_id: String,
    pub expires_at: i64,
}

async fn create_invite(
    State(state): State<AppState>,
    dev: AuthDevice,
    Json(req): Json<CreateInvite>,
) -> ApiResult<(StatusCode, Json<InviteCreated>)> {
    if !valid_id(&req.invite_id) || req.invite_id.len() < 22 {
        return Err(bad("invite id must be at least 128 bits"));
    }
    let payload = decode_b64(&req.payload, 1024)?;
    let expires_at = now() + INVITE_TTL_SECS;
    let conn = state.db.lock().unwrap();
    conn.execute("DELETE FROM invites WHERE expires_at < ?1", params![now()])?;
    conn.execute(
        "INSERT INTO invites (id, vault_id, payload, created_by, expires_at) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![req.invite_id, dev.vault_id, payload, dev.id, expires_at],
    )
    .map_err(|_| ApiError(StatusCode::CONFLICT, "invite exists"))?;
    Ok((
        StatusCode::CREATED,
        Json(InviteCreated {
            invite_id: req.invite_id,
            expires_at,
        }),
    ))
}

#[derive(Deserialize)]
pub struct Claim {
    pub device_name: String,
}

#[derive(Serialize, Deserialize)]
pub struct Claimed {
    pub device: DeviceToken,
    pub payload: String,
    pub key_epoch: i64,
}

async fn claim_invite(
    State(state): State<AppState>,
    ClientAddr(addr): ClientAddr,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(req): Json<Claim>,
) -> ApiResult<Json<Claimed>> {
    state
        .limiter
        .check(format!("claim|{}", client_key(&state, &headers, addr)))?;
    let mut conn = state.db.lock().unwrap();
    let tx = conn.transaction()?;
    let row: Option<(String, Vec<u8>, i64, Option<i64>)> = tx
        .query_row(
            "SELECT vault_id, payload, expires_at, claimed_at FROM invites WHERE id = ?1",
            params![id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()?;
    let Some((vault, payload, expires_at, claimed)) = row else {
        return Err(ApiError(StatusCode::NOT_FOUND, "no such invite"));
    };
    if claimed.is_some() || expires_at < now() {
        return Err(ApiError(StatusCode::GONE, "invite expired or used"));
    }
    tx.execute(
        "UPDATE invites SET claimed_at = ?1, payload = x'' WHERE id = ?2",
        params![now(), id],
    )?;
    let (device_id, token) = issue_device(&tx, &vault, &device_name(&req.device_name))?;
    let epoch: i64 = tx.query_row(
        "SELECT key_epoch FROM vaults WHERE id = ?1",
        params![vault],
        |r| r.get(0),
    )?;
    tx.commit()?;
    tracing::info!(vault = %vault, device = %device_id, "device paired");
    Ok(Json(Claimed {
        device: DeviceToken {
            vault_id: vault,
            device_id,
            token,
        },
        payload: B64.encode(payload),
        key_epoch: epoch,
    }))
}

// ---------------------------------------------------------------- recovery

#[derive(Deserialize)]
pub struct Recover {
    pub vault_id: String,
    pub recovery_auth: String,
    pub device_name: String,
}

#[derive(Serialize, Deserialize)]
pub struct Recovered {
    pub device: DeviceToken,
    pub wrapped_key: String,
    pub key_epoch: i64,
}

async fn recover(
    State(state): State<AppState>,
    ClientAddr(addr): ClientAddr,
    headers: HeaderMap,
    Json(req): Json<Recover>,
) -> ApiResult<Json<Recovered>> {
    let who = client_key(&state, &headers, addr);
    state.limiter.check(format!("recover|{who}"))?;
    state
        .limiter
        .check(format!("recover-vault|{}", req.vault_id))?;
    let auth = decode_b64(&req.recovery_auth, 64)?;
    let conn = state.db.lock().unwrap();
    let row: Option<(Vec<u8>, Vec<u8>, i64)> = conn
        .query_row(
            "SELECT recovery_auth_hash, wrapped_key, key_epoch FROM vaults WHERE id = ?1",
            params![req.vault_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    // Same response for unknown vault and wrong key.
    let Some((_, wrapped, epoch)) = row.filter(|(h, _, _)| ct_eq(h, &sha256(&auth))) else {
        tracing::warn!(vault = %req.vault_id, from = %who, "recovery failed");
        return Err(ApiError(StatusCode::UNAUTHORIZED, "recovery failed"));
    };
    let (device_id, token) = issue_device(&conn, &req.vault_id, &device_name(&req.device_name))?;
    tracing::info!(vault = %req.vault_id, device = %device_id, "device enrolled by recovery key");
    Ok(Json(Recovered {
        device: DeviceToken {
            vault_id: req.vault_id,
            device_id,
            token,
        },
        wrapped_key: B64.encode(wrapped),
        key_epoch: epoch,
    }))
}
