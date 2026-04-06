CREATE TABLE widget_data (
    key TEXT PRIMARY KEY,
    data TEXT NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE TABLE auth_cache (
    token_hash TEXT PRIMARY KEY,
    org_id TEXT NOT NULL,
    expires_at INTEGER NOT NULL
);
