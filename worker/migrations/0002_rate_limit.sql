-- Simple fixed-window rate limiter bucket. bucket_key = "<ip>:<minute>" or "<ip>:put:<minute>".
CREATE TABLE IF NOT EXISTS rate_limit (
    bucket_key TEXT PRIMARY KEY,
    count INTEGER NOT NULL,
    window_start INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_rate_limit_window ON rate_limit(window_start);
