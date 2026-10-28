use axum::{
    body::Body,
    http::{Request, StatusCode},
    Router,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use tube_sync::{db, router, AppState};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;

fn app(registration: Option<&str>) -> Router {
    let conn = db::open(":memory:").unwrap();
    router(AppState::new(conn, registration.map(String::from), false))
}

async fn call(
    app: &Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Value,
) -> (StatusCode, Value) {
    let mut req = Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json");
    if let Some(t) = token {
        req = req.header("authorization", format!("Bearer {t}"));
    }
    let body = if body.is_null() {
        Body::empty()
    } else {
        Body::from(body.to_string())
    };
    let resp = app.clone().oneshot(req.body(body).unwrap()).await.unwrap();
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let v = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or(Value::Null)
    };
    (status, v)
}

fn b64(n: usize, fill: u8) -> String {
    B64.encode(vec![fill; n])
}

async fn create(app: &Router, vault: &str) -> String {
    let (s, v) = call(app, "POST", "/v1/vaults", None, json!({
        "vault_id": vault, "wrapped_key": b64(60, 1), "recovery_auth": b64(32, 9), "device_name": "phone"
    })).await;
    assert_eq!(s, StatusCode::CREATED, "{v}");
    v["token"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn push_pull_between_devices() {
    let app = app(None);
    let a = create(&app, "vault1").await;

    let (s, v) = call(
        &app,
        "POST",
        "/v1/records",
        Some(&a),
        json!({"records": [
            {"id": "h1", "kind": "host", "base_version": 0, "epoch": 1, "ciphertext": b64(40, 2)},
            {"id": "s1", "kind": "snippet", "base_version": 0, "epoch": 1, "ciphertext": b64(40, 3)}
        ]}),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["applied"].as_array().unwrap().len(), 2);

    // second device via recovery
    let (s, v) = call(
        &app,
        "POST",
        "/v1/recover",
        None,
        json!({
            "vault_id": "vault1", "recovery_auth": b64(32, 9), "device_name": "ipad"
        }),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    assert_eq!(v["wrapped_key"], b64(60, 1));
    let b = v["device"]["token"].as_str().unwrap().to_string();

    let (_, v) = call(&app, "GET", "/v1/records?since=0", Some(&b), Value::Null).await;
    let recs = v["records"].as_array().unwrap();
    assert_eq!(recs.len(), 2);
    assert_eq!(recs[0]["ciphertext"], b64(40, 2));
    let cursor = v["cursor"].as_i64().unwrap();

    // B edits h1; A pulls only the change
    let (_, v) = call(
        &app,
        "POST",
        "/v1/records",
        Some(&b),
        json!({"records": [
            {"id": "h1", "kind": "host", "base_version": 1, "epoch": 1, "ciphertext": b64(40, 4)}
        ]}),
    )
    .await;
    assert_eq!(v["applied"][0]["version"], 2);
    let (_, v) = call(
        &app,
        "GET",
        &format!("/v1/records?since={cursor}"),
        Some(&a),
        Value::Null,
    )
    .await;
    let recs = v["records"].as_array().unwrap();
    assert_eq!(recs.len(), 1);
    assert_eq!(recs[0]["id"], "h1");
    assert_eq!(recs[0]["version"], 2);
}

#[tokio::test]
async fn stale_base_version_is_a_conflict() {
    let app = app(None);
    let a = create(&app, "v").await;
    call(
        &app,
        "POST",
        "/v1/records",
        Some(&a),
        json!({"records": [
            {"id": "h1", "kind": "host", "base_version": 0, "epoch": 1, "ciphertext": b64(20, 1)}
        ]}),
    )
    .await;
    call(
        &app,
        "POST",
        "/v1/records",
        Some(&a),
        json!({"records": [
            {"id": "h1", "kind": "host", "base_version": 1, "epoch": 1, "ciphertext": b64(20, 2)}
        ]}),
    )
    .await;
    // offline device still thinks version is 1
    let (s, v) = call(
        &app,
        "POST",
        "/v1/records",
        Some(&a),
        json!({"records": [
            {"id": "h1", "kind": "host", "base_version": 1, "epoch": 1, "ciphertext": b64(20, 3)}
        ]}),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    assert!(v["applied"].as_array().unwrap().is_empty());
    assert_eq!(v["conflicts"][0]["version"], 2);
    assert_eq!(v["conflicts"][0]["ciphertext"], b64(20, 2));
}

#[tokio::test]
async fn tombstones_and_kind_is_fixed() {
    let app = app(None);
    let a = create(&app, "v").await;
    call(
        &app,
        "POST",
        "/v1/records",
        Some(&a),
        json!({"records": [
            {"id": "x", "kind": "host", "base_version": 0, "epoch": 1, "ciphertext": b64(20, 1)}
        ]}),
    )
    .await;
    let (s, _) = call(
        &app,
        "POST",
        "/v1/records",
        Some(&a),
        json!({"records": [
            {"id": "x", "kind": "identity", "base_version": 1, "epoch": 1, "ciphertext": b64(20, 1)}
        ]}),
    )
    .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    let (_, v) = call(
        &app,
        "POST",
        "/v1/records",
        Some(&a),
        json!({"records": [
            {"id": "x", "kind": "host", "base_version": 1, "epoch": 1, "deleted": true}
        ]}),
    )
    .await;
    assert_eq!(v["applied"][0]["version"], 2);
    let (_, v) = call(&app, "GET", "/v1/records", Some(&a), Value::Null).await;
    assert_eq!(v["records"][0]["deleted"], true);
    assert!(v["records"][0]["ciphertext"].is_null());
}

#[tokio::test]
async fn revoked_device_loses_access_and_its_invites() {
    let app = app(None);
    let a = create(&app, "v").await;
    let (_, v) = call(
        &app,
        "POST",
        "/v1/recover",
        None,
        json!({
            "vault_id": "v", "recovery_auth": b64(32, 9), "device_name": "laptop"
        }),
    )
    .await;
    let b = v["device"]["token"].as_str().unwrap().to_string();
    let b_id = v["device"]["device_id"].as_str().unwrap().to_string();

    let (s, _) = call(
        &app,
        "POST",
        "/v1/pairing",
        Some(&b),
        json!({
            "invite_id": "AAAAAAAAAAAAAAAAAAAAAAAA", "payload": b64(60, 5)
        }),
    )
    .await;
    assert_eq!(s, StatusCode::CREATED);

    let (s, _) = call(
        &app,
        "DELETE",
        &format!("/v1/devices/{b_id}"),
        Some(&a),
        Value::Null,
    )
    .await;
    assert_eq!(s, StatusCode::NO_CONTENT);

    let (s, _) = call(&app, "GET", "/v1/records", Some(&b), Value::Null).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, _) = call(
        &app,
        "POST",
        "/v1/pairing/AAAAAAAAAAAAAAAAAAAAAAAA/claim",
        None,
        json!({"device_name": "x"}),
    )
    .await;
    assert_eq!(s, StatusCode::NOT_FOUND);

    let (_, v) = call(&app, "GET", "/v1/devices", Some(&a), Value::Null).await;
    let laptop = v
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["name"] == "laptop")
        .unwrap();
    assert_eq!(laptop["revoked"], true);
}

#[tokio::test]
async fn key_rotation_bumps_epoch_and_rejects_stale_writes() {
    let app = app(None);
    let a = create(&app, "v").await;
    let (s, _) = call(
        &app,
        "PUT",
        "/v1/vault/key",
        Some(&a),
        json!({"wrapped_key": b64(60, 7), "key_epoch": 3}),
    )
    .await;
    assert_eq!(s, StatusCode::CONFLICT);
    let (s, _) = call(
        &app,
        "PUT",
        "/v1/vault/key",
        Some(&a),
        json!({"wrapped_key": b64(60, 7), "key_epoch": 2}),
    )
    .await;
    assert_eq!(s, StatusCode::NO_CONTENT);
    let (_, v) = call(&app, "GET", "/v1/vault", Some(&a), Value::Null).await;
    assert_eq!(v["key_epoch"], 2);
    let (s, _) = call(
        &app,
        "POST",
        "/v1/records",
        Some(&a),
        json!({"records": [
            {"id": "h", "kind": "host", "base_version": 0, "epoch": 1, "ciphertext": b64(20, 1)}
        ]}),
    )
    .await;
    assert_eq!(s, StatusCode::CONFLICT);
}

#[tokio::test]
async fn pairing_is_single_use() {
    let app = app(None);
    let a = create(&app, "v").await;
    let invite = "BBBBBBBBBBBBBBBBBBBBBBBBBB";
    call(
        &app,
        "POST",
        "/v1/pairing",
        Some(&a),
        json!({"invite_id": invite, "payload": b64(60, 5)}),
    )
    .await;
    let (s, v) = call(
        &app,
        "POST",
        &format!("/v1/pairing/{invite}/claim"),
        None,
        json!({"device_name": "tablet"}),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["payload"], b64(60, 5));
    assert_eq!(v["device"]["vault_id"], "v");
    let (s, _) = call(
        &app,
        "POST",
        &format!("/v1/pairing/{invite}/claim"),
        None,
        json!({"device_name": "evil"}),
    )
    .await;
    assert_eq!(s, StatusCode::GONE);
}

#[tokio::test]
async fn short_invite_ids_are_refused() {
    let app = app(None);
    let a = create(&app, "v").await;
    let (s, _) = call(
        &app,
        "POST",
        "/v1/pairing",
        Some(&a),
        json!({"invite_id": "short", "payload": b64(60, 5)}),
    )
    .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn wrong_recovery_auth_and_unknown_vault_look_the_same() {
    let app = app(None);
    create(&app, "v").await;
    let (s1, v1) = call(
        &app,
        "POST",
        "/v1/recover",
        None,
        json!({"vault_id": "v", "recovery_auth": b64(32, 8), "device_name": "x"}),
    )
    .await;
    let (s2, v2) = call(
        &app,
        "POST",
        "/v1/recover",
        None,
        json!({"vault_id": "nope", "recovery_auth": b64(32, 8), "device_name": "x"}),
    )
    .await;
    assert_eq!(s1, StatusCode::UNAUTHORIZED);
    assert_eq!((s1, v1), (s2, v2));
}

#[tokio::test]
async fn recovery_is_rate_limited_per_vault() {
    let app = app(None);
    create(&app, "v").await;
    let mut last = StatusCode::OK;
    for _ in 0..12 {
        let (s, _) = call(
            &app,
            "POST",
            "/v1/recover",
            None,
            json!({"vault_id": "v", "recovery_auth": b64(32, 8), "device_name": "x"}),
        )
        .await;
        last = s;
    }
    assert_eq!(last, StatusCode::TOO_MANY_REQUESTS);
}

#[tokio::test]
async fn registration_token_required_when_configured() {
    let app = app(Some("letmein"));
    let (s, _) = call(&app, "POST", "/v1/vaults", None, json!({
        "vault_id": "v", "wrapped_key": b64(60, 1), "recovery_auth": b64(32, 9), "device_name": "phone"
    })).await;
    assert_eq!(s, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn devices_cannot_read_other_vaults() {
    let app = app(None);
    let a = create(&app, "va").await;
    let b = create(&app, "vb").await;
    call(&app, "POST", "/v1/records", Some(&a), json!({"records": [
        {"id": "secret", "kind": "host", "base_version": 0, "epoch": 1, "ciphertext": b64(20, 1)}
    ]})).await;
    let (_, v) = call(&app, "GET", "/v1/records", Some(&b), Value::Null).await;
    assert!(v["records"].as_array().unwrap().is_empty());
    // Writing the same id in vault b does not touch vault a.
    let (_, v) = call(&app, "POST", "/v1/records", Some(&b), json!({"records": [
        {"id": "secret", "kind": "host", "base_version": 0, "epoch": 1, "ciphertext": b64(20, 2)}
    ]})).await;
    assert_eq!(v["applied"][0]["version"], 1);
}
