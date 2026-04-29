interface Env {
	DB: D1Database;
}

interface PutBody {
	data: {
		fiveHourUtilization: number;
		sevenDayUtilization: number;
		fiveHourPace: number | null;
		sevenDayPace: number | null;
		fiveHourResetsAt: number | null;
		sevenDayResetsAt: number | null;
		updatedAt: number;
		// v2 fields
		extraUsageEnabled?: boolean | null;
		depletionSeconds?: number | null;
		activeSessionCount?: number | null;
		// v3 fields — analytics app
		opusUtilization?: number | null;
		sonnetUtilization?: number | null;
		haikuUtilization?: number | null;
		dailyEntries?: { date: string; usage: number }[] | null;
		sessions?: { project: string; model?: string | null; tokens?: number | null; durationSeconds?: number | null }[] | null;
		extraUsageUtilization?: number | null;
	};
}

async function sha256hex(input: string): Promise<string> {
	const data = new TextEncoder().encode(input);
	const hash = await crypto.subtle.digest('SHA-256', data);
	return [...new Uint8Array(hash)].map(b => b.toString(16).padStart(2, '0')).join('');
}

/** Fixed-window-per-minute rate limiter. Returns true if request allowed, false if over limit.
 *  Uses `RETURNING count` so the increment and read happen in a single atomic statement —
 *  a separate SELECT could read a count that includes other concurrent requests' increments,
 *  producing spurious 429s near the limit. */
async function checkRateLimit(
	env: Env,
	bucketId: string,
	limitPerMinute: number,
): Promise<boolean> {
	const nowSec = Math.floor(Date.now() / 1000);
	const windowStart = nowSec - (nowSec % 60); // bucket per minute
	const key = `${bucketId}:${windowStart}`;
	const row = await env.DB.prepare(
		'INSERT INTO rate_limit (bucket_key, count, window_start) VALUES (?, 1, ?) ' +
		'ON CONFLICT(bucket_key) DO UPDATE SET count = count + 1 ' +
		'RETURNING count',
	).bind(key, windowStart).first<{ count: number }>();
	return (row?.count ?? 0) <= limitPerMinute;
}

/** Extract client IP from Cloudflare request headers. Falls back to a constant so the limit
 *  still applies (worst case everyone shares a bucket — not what we want in prod but not a crash). */
function clientIp(request: Request): string {
	return request.headers.get('cf-connecting-ip')
		|| request.headers.get('x-forwarded-for')?.split(',')[0].trim()
		|| 'unknown';
}

async function validateToken(accessToken: string): Promise<string | null> {
	const resp = await fetch('https://api.anthropic.com/api/oauth/usage', {
		headers: {
			'Authorization': `Bearer ${accessToken}`,
			'anthropic-beta': 'oauth-2025-04-20',
		},
	});
	if (resp.status !== 200) return null;
	return resp.headers.get('anthropic-organization-id');
}

async function handlePut(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
	const auth = request.headers.get('Authorization');
	if (!auth?.startsWith('Bearer ')) {
		return new Response('Missing Authorization header', { status: 401 });
	}
	const accessToken = auth.slice(7);

	// Per-IP PUT rate limit: blunts auth-brute-force / spam even before we validate the token.
	// Legitimate Mac app pushes ~12/hour. 30/min leaves ample headroom for heartbeats + retries.
	const ip = clientIp(request);
	if (!(await checkRateLimit(env, `put:ip:${ip}`, 30))) {
		return new Response('Rate limited', { status: 429, headers: { 'Retry-After': '60' } });
	}

	let body: PutBody;
	try {
		body = await request.json() as PutBody;
	} catch {
		return new Response('Invalid JSON', { status: 400 });
	}

	if (!body.data) {
		return new Response('Missing data', { status: 400 });
	}

	// Check auth cache to avoid validating on every request
	const tokenHash = await sha256hex(accessToken);
	const now = Math.floor(Date.now() / 1000);
	const cached = await env.DB.prepare(
		'SELECT org_id FROM auth_cache WHERE token_hash = ? AND expires_at > ?'
	).bind(tokenHash, now).first<{ org_id: string }>();

	let orgId: string | null = cached?.org_id ?? null;

	if (!orgId) {
		orgId = await validateToken(accessToken);
		if (!orgId) {
			return new Response('Invalid token', { status: 401 });
		}
		await env.DB.prepare(
			'INSERT OR REPLACE INTO auth_cache (token_hash, org_id, expires_at) VALUES (?, ?, ?)'
		).bind(tokenHash, orgId, now + 3600).run();
	}

	// Per-org PUT rate limit: one compromised/misbehaving org can't DoS the shared worker.
	if (!(await checkRateLimit(env, `put:org:${orgId}`, 60))) {
		return new Response('Rate limited', { status: 429, headers: { 'Retry-After': '60' } });
	}

	const canonicalKey = await sha256hex(orgId);
	const newValue = JSON.stringify(body.data);
	const ttl = 86400; // 24h — Mac pushes ~every 60s, but widget needs data when Mac is asleep.

	// Single write path. The client already suppresses spammy pushes via shouldPushWidget()
	// (value change OR 5-minute heartbeat), so the previous two-branch "dedup" on the server
	// was dead weight: both branches rewrote `data` anyway. Collapsing removes an extra D1 read
	// and simplifies the hot path.
	await env.DB.prepare(
		'INSERT OR REPLACE INTO widget_data (key, data, expires_at) VALUES (?, ?, ?)'
	).bind(canonicalKey, newValue, now + ttl).run();

	// Opportunistic cleanup of expired rows (~1% of requests). `waitUntil` keeps the worker
	// alive until these finish — without it the response resolves first and Workers may drop
	// the pending promises, so the rate_limit / auth_cache / widget_data tables grow unbounded.
	if (Math.random() < 0.01) {
		ctx.waitUntil(env.DB.prepare('DELETE FROM auth_cache WHERE expires_at < ?').bind(now).run());
		ctx.waitUntil(env.DB.prepare('DELETE FROM widget_data WHERE expires_at < ?').bind(now).run());
		// Rate limit buckets are one minute wide; anything more than 2 minutes old is useless.
		ctx.waitUntil(env.DB.prepare('DELETE FROM rate_limit WHERE window_start < ?').bind(now - 120).run());
	}

	return Response.json({ key: canonicalKey });
}

async function handleGet(key: string, env: Env, ctx: ExecutionContext, request: Request): Promise<Response> {
	// Rate limit: 120 GET/min per IP. Legitimate widgets refresh every ~2min; this is generous
	// for a shared NAT but cheap enough to blunt brute-force enumeration.
	const ip = clientIp(request);
	if (!(await checkRateLimit(env, `get:${ip}`, 120))) {
		return new Response('Rate limited', { status: 429, headers: { 'Retry-After': '60' } });
	}

	const now = Math.floor(Date.now() / 1000);

	// Opportunistic cleanup of expired rows (~1% of requests). The GET path is polled far more
	// frequently than PUT by the iOS widget, so without this the rate_limit table accumulates
	// one row per IP per minute indefinitely. `waitUntil` ensures these run to completion.
	if (Math.random() < 0.01) {
		ctx.waitUntil(env.DB.prepare('DELETE FROM rate_limit WHERE window_start < ?').bind(now - 120).run());
		ctx.waitUntil(env.DB.prepare('DELETE FROM widget_data WHERE expires_at < ?').bind(now).run());
	}
	const row = await env.DB.prepare(
		'SELECT data FROM widget_data WHERE key = ? AND expires_at > ?'
	).bind(key, now).first<{ data: string }>();

	if (!row) {
		return new Response('Not found', { status: 404 });
	}
	return new Response(row.data, {
		headers: {
			'Content-Type': 'application/json',
			// Widget clients make their own decisions about polling cadence; do NOT let CDN cache
			// this response, otherwise stale data would be served even after the Mac pushes updates.
			'Cache-Control': 'private, no-store, max-age=0',
		},
	});
}

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const url = new URL(request.url);
		const path = url.pathname;

		if (path === '/health') {
			return Response.json({ status: 'ok' });
		}

		if (path === '/widget' && request.method === 'PUT') {
			return handlePut(request, env, ctx);
		}

		const match = path.match(/^\/widget\/([a-f0-9]{64})$/);
		if (match && request.method === 'GET') {
			return handleGet(match[1], env, ctx, request);
		}

		return new Response('Not found', { status: 404 });
	},
} satisfies ExportedHandler<Env>;
