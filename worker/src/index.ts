interface Env {
	CCUSAGE_WIDGET: KVNamespace;
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
	};
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
	const authCacheKey = `auth:${tokenHash}`;
	let orgId = await env.CCUSAGE_WIDGET.get(authCacheKey);

	if (!orgId) {
		orgId = await validateToken(accessToken);
		if (!orgId) {
			return new Response('Invalid token', { status: 401 });
		}
		await env.CCUSAGE_WIDGET.put(authCacheKey, orgId, { expirationTtl: 300 });
	}

	const canonicalKey = await sha256hex(orgId);
	await env.CCUSAGE_WIDGET.put(`widget:${canonicalKey}`, JSON.stringify(body.data), { expirationTtl: 3600 });

	return Response.json({ key: canonicalKey });
}

async function handleGet(key: string, env: Env): Promise<Response> {
	const data = await env.CCUSAGE_WIDGET.get(`widget:${key}`);
	if (!data) {
		return new Response('Not found', { status: 404 });
	}
	return new Response(data, {
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
