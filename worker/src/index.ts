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
		todayCost?: number | null;
		activeSessionCount?: number | null;
		// v3 fields — analytics app
		opusUtilization?: number | null;
		sonnetUtilization?: number | null;
		haikuUtilization?: number | null;
		dailyEntries?: { date: string; usage: number }[] | null;
		dailyCosts?: { date: string; cost: number }[] | null;
		sessions?: { project: string; model?: string | null; tokens?: number | null; durationSeconds?: number | null }[] | null;
		extraUsageUtilization?: number | null;
	};
}

function sameExceptUpdatedAt(a: string, b: string): boolean {
	try {
		const objA = JSON.parse(a);
		const objB = JSON.parse(b);
		const { updatedAt: _a, ...restA } = objA;
		const { updatedAt: _b, ...restB } = objB;
		return JSON.stringify(restA) === JSON.stringify(restB);
	} catch {
		return false;
	}
}

async function sha256hex(input: string): Promise<string> {
	const data = new TextEncoder().encode(input);
	const hash = await crypto.subtle.digest('SHA-256', data);
	return [...new Uint8Array(hash)].map(b => b.toString(16).padStart(2, '0')).join('');
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

async function handlePut(request: Request, env: Env): Promise<Response> {
	const auth = request.headers.get('Authorization');
	if (!auth?.startsWith('Bearer ')) {
		return new Response('Missing Authorization header', { status: 401 });
	}
	const accessToken = auth.slice(7);

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

	const canonicalKey = await sha256hex(orgId);
	const newValue = JSON.stringify(body.data);

	// Read-before-write: free tier has 5M reads/day but only 100K writes/day.
	const existing = await env.DB.prepare(
		'SELECT data FROM widget_data WHERE key = ? AND expires_at > ?'
	).bind(canonicalKey, now).first<{ data: string }>();

	if (!existing || !sameExceptUpdatedAt(existing.data, newValue)) {
		await env.DB.prepare(
			'INSERT OR REPLACE INTO widget_data (key, data, expires_at) VALUES (?, ?, ?)'
		).bind(canonicalKey, newValue, now + 3600).run();
	}

	// Opportunistic cleanup of expired rows (~1% of requests)
	if (Math.random() < 0.01) {
		env.DB.prepare('DELETE FROM auth_cache WHERE expires_at < ?').bind(now).run();
		env.DB.prepare('DELETE FROM widget_data WHERE expires_at < ?').bind(now).run();
	}

	return Response.json({ key: canonicalKey });
}

async function handleGet(key: string, env: Env): Promise<Response> {
	const now = Math.floor(Date.now() / 1000);
	const row = await env.DB.prepare(
		'SELECT data FROM widget_data WHERE key = ? AND expires_at > ?'
	).bind(key, now).first<{ data: string }>();

	if (!row) {
		return new Response('Not found', { status: 404 });
	}
	return new Response(row.data, {
		headers: { 'Content-Type': 'application/json' },
	});
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		const path = url.pathname;

		if (path === '/health') {
			return Response.json({ status: 'ok' });
		}

		if (path === '/widget' && request.method === 'PUT') {
			return handlePut(request, env);
		}

		const match = path.match(/^\/widget\/([a-f0-9]{64})$/);
		if (match && request.method === 'GET') {
			return handleGet(match[1], env);
		}

		return new Response('Not found', { status: 404 });
	},
} satisfies ExportedHandler<Env>;
