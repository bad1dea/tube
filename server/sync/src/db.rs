use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

pub const SCHEMA: &str = r#"
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS vaults (
    id TEXT PRIMARY KEY,
    wrapped_key BLOB NOT NULL,
    key_epoch INTEGER NOT NULL DEFAULT 1,
    recovery_auth_hash BLOB NOT NULL,
    next_seq INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    token_hash BLOB NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    last_seen INTEGER NOT NULL,
    revoked_at INTEGER
);
CREATE TABLE IF NOT EXISTS records (
    vault_id TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    kind TEXT NOT NULL,
    version INTEGER NOT NULL,
    epoch INTEGER NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    ciphertext BLOB,
    seq INTEGER NOT NULL,
    updated_by TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (vault_id, id)
);
CREATE INDEX IF NOT EXISTS records_seq ON records(vault_id, seq);
CREATE TABLE IF NOT EXISTS invites (
    id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
    payload BLOB NOT NULL,
    created_by TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    claimed_at INTEGER
);
"#;

pub fn open(path: &str) -> rusqlite::Result<Connection> {
    let conn = Connection::open(path)?;
    conn.execute_batch(SCHEMA)?;
    Ok(conn)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Record {
    pub id: String,
    pub kind: String,
    pub version: i64,
    pub epoch: i64,
    pub deleted: bool,
    /// base64 of nonce || ciphertext || tag; null for tombstones.
    pub ciphertext: Option<String>,
    pub seq: i64,
    pub updated_by: String,
    pub updated_at: i64,
}

pub struct Device {
    pub id: String,
    pub vault_id: String,
}

pub fn device_by_token_hash(conn: &Connection, hash: &[u8]) -> rusqlite::Result<Option<Device>> {
    conn.query_row(
        "SELECT id, vault_id FROM devices WHERE token_hash = ?1 AND revoked_at IS NULL",
        params![hash],
        |r| {
            Ok(Device {
                id: r.get(0)?,
                vault_id: r.get(1)?,
            })
        },
    )
    .optional()
}

pub fn records_since(
    conn: &Connection,
    vault: &str,
    since: i64,
    limit: i64,
) -> rusqlite::Result<Vec<Record>> {
    let mut stmt = conn.prepare(
        "SELECT id, kind, version, epoch, deleted, ciphertext, seq, updated_by, updated_at
         FROM records WHERE vault_id = ?1 AND seq > ?2 ORDER BY seq LIMIT ?3",
    )?;
    let rows = stmt.query_map(params![vault, since, limit], row_to_record)?;
    rows.collect()
}

pub fn record(conn: &Connection, vault: &str, id: &str) -> rusqlite::Result<Option<Record>> {
    conn.query_row(
        "SELECT id, kind, version, epoch, deleted, ciphertext, seq, updated_by, updated_at
         FROM records WHERE vault_id = ?1 AND id = ?2",
        params![vault, id],
        row_to_record,
    )
    .optional()
}

fn row_to_record(r: &rusqlite::Row) -> rusqlite::Result<Record> {
    use base64::Engine;
    let ct: Option<Vec<u8>> = r.get(5)?;
    Ok(Record {
        id: r.get(0)?,
        kind: r.get(1)?,
        version: r.get(2)?,
        epoch: r.get(3)?,
        deleted: r.get::<_, i64>(4)? != 0,
        ciphertext: ct.map(|b| base64::engine::general_purpose::STANDARD.encode(b)),
        seq: r.get(6)?,
        updated_by: r.get(7)?,
        updated_at: r.get(8)?,
    })
}
