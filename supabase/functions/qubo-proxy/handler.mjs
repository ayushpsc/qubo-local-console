const APP = 'srvcapp.platform.quboworld.com';
const STORAGE = new Map([
  ['north-az1-s3.cloud.airtel.in', {region: 'nz', port: '10446'}],
  ['south-az1-s3.cloud.airtel.in', {region: 'sz', port: '10445'}],
]);
const MEDIA_HOST = 'heroiot-prod-push-pull.s3.ap-south-1.amazonaws.com';
const GOOGLE_HOME = 'googlehomefoyer-pa.googleapis.com';
const GOOGLE_HOME_METHOD = '/google.internal.home.foyer.v1.HomeControlService/UpdateTraits';
const LIVE_HOST = '13.235.191.60';
const LIVE_PORT = '1935';
const APP_HEADERS = ['app-id', 'token-type', 'source-device-id', 'source', 'user-uuid',
  'subscriber-key', 'authorization', 'content-type', 'accept', 'app-type', 'login-device-name'];
const GOOGLE_HEADERS = ['x-google-authorization', 'x-google-ext', 'x-google-environment',
  'x-google-accept-language', 'x-google-grpc-timeout'];
const CORS_HEADERS = [...APP_HEADERS, ...GOOGLE_HEADERS, 'range'];
const FIREBASE_KEYS_URL =
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';
let firebaseKeyCache = {expiresAt: 0, keys: new Map()};

function base64UrlBytes(value) {
  const base64 = value.replaceAll('-', '+').replaceAll('_', '/');
  const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, '=');
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function jwtJson(value) {
  return JSON.parse(new TextDecoder().decode(base64UrlBytes(value)));
}

export async function verifyFirebaseIdToken(token, projectId,
  {fetchImpl = fetch, now = Date.now()} = {}) {
  const parts = token.split('.');
  if (parts.length !== 3 || !projectId) throw new Error('Invalid Firebase token');
  let header; let claims;
  try {
    header = jwtJson(parts[0]);
    claims = jwtJson(parts[1]);
  } catch { throw new Error('Invalid Firebase token'); }
  const seconds = Math.floor(now / 1000);
  if (header.alg !== 'RS256' || typeof header.kid !== 'string' || !header.kid ||
      claims.aud !== projectId || claims.iss !== `https://securetoken.google.com/${projectId}` ||
      typeof claims.sub !== 'string' || !claims.sub || claims.sub.length > 128 ||
      !Number.isFinite(claims.exp) || claims.exp <= seconds ||
      !Number.isFinite(claims.iat) || claims.iat > seconds ||
      !Number.isFinite(claims.auth_time) || claims.auth_time > seconds) {
    throw new Error('Invalid Firebase token');
  }
  if (firebaseKeyCache.expiresAt <= now || !firebaseKeyCache.keys.has(header.kid)) {
    const response = await fetchImpl(FIREBASE_KEYS_URL, {redirect: 'error'});
    if (!response.ok) throw new Error('Firebase keys unavailable');
    const document = await response.json();
    const keys = new Map((Array.isArray(document.keys) ? document.keys : [])
      .filter((key) => key && key.kid).map((key) => [key.kid, key]));
    const maxAge = /(?:^|,)\s*max-age=(\d+)/i.exec(response.headers.get('cache-control') || '');
    firebaseKeyCache = {
      keys,
      expiresAt: now + Math.max(300, Number(maxAge?.[1] || 3600)) * 1000,
    };
  }
  const jwk = firebaseKeyCache.keys.get(header.kid);
  if (!jwk) throw new Error('Unknown Firebase signing key');
  const key = await crypto.subtle.importKey(
    'jwk', jwk, {name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256'}, false, ['verify'],
  );
  const valid = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5', key, base64UrlBytes(parts[2]),
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  if (!valid) throw new Error('Invalid Firebase signature');
  return claims;
}

function liveSessionRoot(url) {
  return /^((?:\/hero-iot-live\/HLS_[0-9a-fA-F-]{36}_[0-9]+\/))(?:[A-Za-z0-9._~=-]+\/)*[A-Za-z0-9._~=-]+$/i
    .exec(url.pathname)?.[1] || null;
}

function isLivePath(url) {
  return url.hostname === LIVE_HOST && url.port === LIVE_PORT && url.protocol === 'http:' &&
    liveSessionRoot(url) !== null;
}

export function allowedTarget(value, method) {
  let url;
  try { url = new URL(value); } catch { return null; }
  if (url.username || url.password || url.hash) return null;
  if (method === 'POST' && url.protocol === 'https:' && url.hostname === GOOGLE_HOME &&
      (!url.port || url.port === '443') && url.pathname === GOOGLE_HOME_METHOD && !url.search) return url;
  if (method === 'GET' && isLivePath(url)) return url;
  if (url.protocol !== 'https:') return null;
  if (url.hostname === APP && (!url.port || url.port === '443')) {
    if (['GET', 'POST', 'PUT'].includes(method) &&
        /^\/(sms|unit-entity-management|roi-manager|stream-manager|content-manager|vms|control-monitor)\/api\/v[1-3]\/sp\/[a-zA-Z0-9-]+\//.test(url.pathname)) return url;
    if (method === 'POST' && url.pathname === '/push-pull/request') return url;
    if (method === 'GET' &&
        /^\/push-pull\/transaction\/[0-9a-fA-F-]{36}$/.test(url.pathname)) return url;
  }
  const storage = STORAGE.get(url.hostname);
  if (storage && (!url.port || url.port === storage.port) && method === 'GET' &&
      new RegExp(`^/ar-${storage.region}-hero-iot-prod-(vms|ai)-event/[^/]+/.+`).test(url.pathname)) return url;
  if (url.hostname === MEDIA_HOST && (!url.port || url.port === '443') &&
      method === 'GET' && url.searchParams.has('X-Amz-Signature') &&
      /^\/sdCardMedia--[0-9a-fA-F-]{36}--\/tmp\/mnt\/sdcard0\/.+\.mp4$/.test(decodeURIComponent(url.pathname))) return url;
  return null;
}

export function rewriteHlsPlaylist(text, playlistUrl, gatewayUrl) {
  if (!text.trimStart().startsWith('#EXTM3U')) throw new Error('Invalid HLS playlist');
  const playlist = playlistUrl instanceof URL ? playlistUrl : new URL(playlistUrl);
  const sessionRoot = liveSessionRoot(playlist);
  const proxied = (value) => {
    const resolved = new URL(value, playlist);
    if (!allowedTarget(resolved.toString(), 'GET') || liveSessionRoot(resolved) !== sessionRoot) {
      const error = new Error('Unsupported HLS child URL');
      error.resourceOrigin = resolved.origin;
      error.resourcePath = resolved.pathname;
      throw error;
    }
    const gateway = new URL(gatewayUrl);
    gateway.search = '';
    gateway.searchParams.set('url', resolved.toString());
    return gateway.toString();
  };
  return text.split(/\r?\n/).map((line) => {
    const trimmed = line.trim();
    if (!trimmed) return line;
    if (!trimmed.startsWith('#')) return proxied(trimmed);
    return line.replace(/URI="([^"]+)"/g, (_, value) => `URI="${proxied(value)}"`);
  }).join('\n');
}

export function findLiveMasterUrl(bytes) {
  const text = new TextDecoder('latin1').decode(bytes);
  const matches = text.matchAll(/https?:\/\/[^\x00-\x20"<>]+\/playlist\.m3u8(?:\?[^\x00-\x20"<>]+)?/gi);
  for (const match of matches) {
    const target = allowedTarget(match[0], 'GET');
    if (target && target.pathname.toLowerCase().endsWith('/playlist.m3u8')) {
      return target.toString();
    }
  }
  return null;
}

export function parseGoogleHomeCapture(encoded) {
  if (!encoded || encoded.length > 64 * 1024) throw new Error('Missing capture');
  let bytes;
  try {
    const binary = atob(encoded);
    bytes = Uint8Array.from(binary, (value) => value.charCodeAt(0));
  } catch { throw new Error('Invalid capture encoding'); }
  let boundary = -1;
  for (let index = 0; index < bytes.length - 3; index++) {
    if (bytes[index] === 13 && bytes[index + 1] === 10 &&
        bytes[index + 2] === 13 && bytes[index + 3] === 10) {
      boundary = index;
      break;
    }
  }
  if (boundary < 0) throw new Error('Invalid capture framing');
  const lines = new TextDecoder('latin1').decode(bytes.slice(0, boundary)).replaceAll('\r', '').split('\n');
  if (lines.shift()?.trim() !== `POST ${GOOGLE_HOME_METHOD} HTTP/2`) throw new Error('Wrong capture method');
  const capturedHeaders = new Map();
  for (const line of lines) {
    const split = line.indexOf(':');
    if (split > 0) capturedHeaders.set(line.slice(0, split).trim().toLowerCase(), line.slice(split + 1).trim());
  }
  const capturedHost = capturedHeaders.get('host')?.toLowerCase();
  if (capturedHost !== GOOGLE_HOME && capturedHost !== `${GOOGLE_HOME}:443`) throw new Error('Wrong capture host');
  const authorization = capturedHeaders.get('authorization') || '';
  const extension = capturedHeaders.get('x-goog-ext-202964622-bin') || '';
  const environment = capturedHeaders.get('foyer-gha-environment') || '';
  const encodedHeader = /^[A-Za-z0-9_+/=-]+$/;
  if (!authorization.startsWith('Bearer ') || authorization.length > 8192 ||
      extension.length < 8 || extension.length > 20000 || !encodedHeader.test(extension) ||
      environment.length < 8 || environment.length > 20000 || !encodedHeader.test(environment)) {
    throw new Error('Capture credentials are missing');
  }
  const body = bytes.slice(boundary + 4);
  if (body.length < 6 || body[0] !== 0) throw new Error('Invalid gRPC capture');
  const declared = ((body[1] << 24) >>> 0) + (body[2] << 16) + (body[3] << 8) + body[4];
  if (declared <= 0 || declared !== body.length - 5) throw new Error('Incomplete gRPC capture');
  return {
    authorization, extension, environment, body,
    acceptLanguage: capturedHeaders.get('accept-language') || 'en-IN,en;q=0.8',
    grpcTimeout: capturedHeaders.get('grpc-timeout') || '9999999u',
  };
}

function allowedOrigin(origin, origins) {
  if (!origin || origins.includes(origin)) return true;
  try {
    const url = new URL(origin);
    return url.origin === origin && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname) &&
      ['http:', 'https:'].includes(url.protocol);
  } catch { return false; }
}

export function createProxy({fetchImpl = fetch, timeoutMs = 22000,
  allowedOrigins = ['http://localhost:5173', 'http://localhost:8080'],
  googleHomeCapture = '', publicGatewayUrl = '', firebaseProjectId = '',
  verifyFirebaseTokenImpl = verifyFirebaseIdToken,
} = {}) {
  return async (request) => {
    const headers = new Headers({
      'Cache-Control': 'private, no-store, max-age=0', 'Vary': 'Origin',
      'X-Qubo-Proxy': 'gateway',
      'Access-Control-Expose-Headers': 'X-Qubo-Proxy, X-Qubo-Upstream-Status, Content-Range, Accept-Ranges, Content-Length',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
      'Access-Control-Allow-Headers': CORS_HEADERS.join(', '),
    });
    const fail = (status, code, message, details = {}) => {
      const copy = new Headers(headers);
      copy.set('Content-Type', 'application/json; charset=utf-8');
      return new Response(JSON.stringify({code, message, ...details}), {status, headers: copy});
    };
    const origin = request.headers.get('origin');
    if (!allowedOrigin(origin, allowedOrigins)) return fail(403, 'PROXY_ORIGIN_FORBIDDEN', 'This website is not enabled for the Qubo gateway.');
    if (origin) headers.set('Access-Control-Allow-Origin', origin);
    if (request.method === 'OPTIONS') return new Response(null, {status: 204, headers});
    const gatewayUrl = new URL(request.url);
    const values = gatewayUrl.searchParams.getAll('url');
    const action = gatewayUrl.searchParams.get('action');
    let presetCapture = null;
    let target;
    if (action !== null) {
      if (action !== 'google-home-live' || request.method !== 'POST' || values.length !== 0) {
        return fail(400, 'PROXY_INVALID_ACTION', 'Unsupported gateway action or method.');
      }
      try { presetCapture = parseGoogleHomeCapture(googleHomeCapture); }
      catch { return fail(503, 'PROXY_LIVE_PRESET_MISSING', 'The configured Home request is unavailable.'); }
      target = new URL(`https://${GOOGLE_HOME}${GOOGLE_HOME_METHOD}`);
    } else {
      if (values.length !== 1) return fail(400, 'PROXY_INVALID_TARGET', 'Exactly one Qubo target URL is required.');
      target = allowedTarget(values[0], request.method);
    }
    if (!target) return fail(400, 'PROXY_INVALID_TARGET', 'Unsupported target URL or method.');
    if (firebaseProjectId && (target.hostname === GOOGLE_HOME || isLivePath(target))) {
      const authorization = request.headers.get('authorization') || '';
      if (!authorization.startsWith('Bearer ') || authorization.length > 8192) {
        return fail(401, 'PROXY_FIREBASE_AUTH_REQUIRED', 'Sign in with Firebase to use live view.');
      }
      try {
        await verifyFirebaseTokenImpl(authorization.slice(7), firebaseProjectId);
      } catch {
        return fail(401, 'PROXY_FIREBASE_AUTH_INVALID', 'The Firebase live-view session is invalid or expired.');
      }
    }
    const upstreamHeaders = new Headers();
    if (target.hostname === GOOGLE_HOME) {
      const authorization = presetCapture?.authorization || request.headers.get('x-google-authorization') || '';
      const extension = presetCapture?.extension || request.headers.get('x-google-ext') || '';
      const environment = presetCapture?.environment || request.headers.get('x-google-environment') || '';
      const encoded = /^[A-Za-z0-9_+/=-]+$/;
      if (!authorization.startsWith('Bearer ') || authorization.length > 8192 ||
          extension.length < 8 || extension.length > 20000 || !encoded.test(extension) ||
          environment.length < 8 || environment.length > 20000 || !encoded.test(environment)) {
        return fail(401, 'PROXY_GOOGLE_AUTH_REQUIRED', 'A fresh Google Home capture is required.');
      }
      upstreamHeaders.set('authorization', authorization);
      upstreamHeaders.set('x-goog-ext-202964622-bin', extension);
      upstreamHeaders.set('foyer-gha-environment', environment);
      upstreamHeaders.set('accept-language', presetCapture?.acceptLanguage || request.headers.get('x-google-accept-language') || 'en-IN,en;q=0.8');
      upstreamHeaders.set('grpc-timeout', presetCapture?.grpcTimeout || request.headers.get('x-google-grpc-timeout') || '9999999u');
      upstreamHeaders.set('content-type', 'application/grpc');
      upstreamHeaders.set('te', 'trailers');
      // Request an uncompressed protobuf frame so the browser can extract the
      // private-schema cameraStreamAccessUrl without owning Google's proto.
      upstreamHeaders.set('grpc-accept-encoding', 'identity');
      upstreamHeaders.set('user-agent', 'grpc-java-okhttp/1.86.0-SNAPSHOT');
    } else if (target.hostname === APP) {
      for (const name of APP_HEADERS) {
        const value = request.headers.get(name);
        if (value) upstreamHeaders.set(name, value);
      }
      // Native app headers are set server-side; browsers cannot set User-Agent.
      upstreamHeaders.set('user-agent', 'Qubo/29 CFNetwork/3860.600.12 Darwin/25.5.0');
      upstreamHeaders.set('accept-language', 'en-IN,en;q=0.9');
      const phoneLogin = /^\/sms\/api\/v1\/sp\/[^/]+\/user\/phone\/(login|verify)$/.test(target.pathname) &&
        !target.search;
      const emailLogin = /^\/sms\/api\/v1\/sp\/[^/]+\/user\/login$/.test(target.pathname) &&
        target.searchParams.size === 1 && target.searchParams.get('system') === 'CS';
      const login = phoneLogin || emailLogin;
      if (!login && (!upstreamHeaders.has('subscriber-key') || !upstreamHeaders.has('user-uuid'))) {
        return fail(401, 'PROXY_AUTH_REQUIRED', 'A Qubo subscriber key and user UUID are required.');
      }
    } else if (target.hostname === MEDIA_HOST || isLivePath(target)) {
      const range = request.headers.get('range');
      if (range) upstreamHeaders.set('range', range);
    }
    // Cookies, Supabase Authorization/apikey, Origin and account tokens are not sent to storage.
    let body = presetCapture?.body;
    if (!presetCapture && request.method !== 'GET' && request.body) {
      const reader = request.body.getReader();
      const chunks = []; let length = 0;
      try {
        while (true) {
          const {value, done} = await reader.read();
          if (done) break;
          length += value.byteLength;
          if (length > 256 * 1024) {
            await reader.cancel();
            return fail(413, 'PROXY_BODY_TOO_LARGE', 'Request body exceeds 256 KB.');
          }
          chunks.push(value);
        }
        body = new Uint8Array(length);
        let offset = 0;
        for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
      } catch { return fail(400, 'PROXY_INVALID_BODY', 'Could not read the request body.'); }
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const upstream = await fetchImpl(target.toString(), {
        method: request.method, headers: upstreamHeaders, body,
        signal: controller.signal, redirect: 'manual',
      });
      if (upstream.status >= 300 && upstream.status < 400) {
        await upstream.body?.cancel();
        return fail(502, 'PROXY_UPSTREAM_REDIRECT', 'The upstream returned an unexpected redirect.');
      }
      const liveAsset = isLivePath(target) && !target.pathname.toLowerCase().endsWith('.m3u8');
      if (target.hostname === MEDIA_HOST || liveAsset) {
        headers.set('X-Qubo-Proxy', 'upstream');
        headers.set('X-Qubo-Upstream-Status', String(upstream.status));
        const successfulMedia = upstream.status >= 200 && upstream.status < 300;
        headers.set('Content-Type', successfulMedia && target.pathname.toLowerCase().endsWith('.mp4')
          ? 'video/mp4' : successfulMedia && target.pathname.toLowerCase().endsWith('.ts')
            ? 'video/mp2t' : (upstream.headers.get('content-type') || 'application/octet-stream'));
        for (const name of ['content-range', 'accept-ranges', 'content-length', 'etag', 'last-modified']) {
          const value = upstream.headers.get(name);
          if (value) headers.set(name, value);
        }
        // Stream media and preserve 206 responses so browsers can seek without
        // buffering the complete SD-card export inside the Edge Function.
        return new Response([204, 205, 304].includes(upstream.status) ? null : upstream.body,
          {status: upstream.status, headers});
      }
      // Buffer bounded responses so the timeout covers the entire transfer.
      const chunks = []; let length = 0;
      if (upstream.body) {
        const reader = upstream.body.getReader();
        while (true) {
          const {value, done} = await reader.read();
          if (done) break;
          length += value.byteLength;
          if (length > 32 * 1024 * 1024) {
            await reader.cancel();
            return fail(502, 'PROXY_RESPONSE_TOO_LARGE', 'The upstream response exceeds 32 MB.');
          }
          chunks.push(value);
        }
      }
      let bytes = new Uint8Array(length);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
      headers.set('X-Qubo-Proxy', 'upstream');
      headers.set('X-Qubo-Upstream-Status', String(upstream.status));
      if (presetCapture && target.hostname === GOOGLE_HOME) {
        const grpcStatus = upstream.headers.get('grpc-status') || '';
        if (upstream.status < 200 || upstream.status >= 300) {
          return fail(
            upstream.status === 401 || upstream.status === 403 ? 401 : 502,
            upstream.status === 401 || upstream.status === 403
              ? 'PROXY_GOOGLE_AUTH_EXPIRED'
              : 'PROXY_LIVE_UPSTREAM_REJECTED',
            upstream.status === 401 || upstream.status === 403
              ? 'The configured Google Home request has expired. Capture a fresh UpdateTraits request.'
              : `Google Home rejected the live request with HTTP ${upstream.status}.`,
          );
        }
        const masterUrl = findLiveMasterUrl(bytes);
        if (!masterUrl) {
          const expired = grpcStatus === '16';
          return fail(
            expired ? 401 : 502,
            expired
              ? 'PROXY_GOOGLE_AUTH_EXPIRED'
              : bytes.length === 0
                ? 'PROXY_LIVE_RESPONSE_EMPTY'
                : 'PROXY_LIVE_RESPONSE_INVALID',
            expired
              ? 'The configured Google Home request has expired. Capture a fresh UpdateTraits request.'
              : bytes.length === 0
                ? 'Google Home returned an empty live-view response. The configured request may have expired.'
                : 'Google Home responded without a supported HLS master URL.',
            {
              responseBytes: bytes.length,
              ...(grpcStatus ? {grpcStatus} : {}),
            },
          );
        }
        const copy = new Headers(headers);
        copy.set('Content-Type', 'application/json; charset=utf-8');
        return new Response(JSON.stringify({masterUrl}), {
          status: 200,
          headers: copy,
        });
      }
      const livePlaylist = isLivePath(target) && target.pathname.toLowerCase().endsWith('.m3u8');
      if (livePlaylist && upstream.status >= 200 && upstream.status < 300) {
        const playlistText = new TextDecoder().decode(bytes);
        if (!playlistText.trim()) {
          headers.set('Retry-After', '2');
          return fail(503, 'PROXY_HLS_NOT_READY', 'The camera stream is still starting.');
        }
        try {
          // Supabase's Edge runtime exposes the function request internally as
          // http://<project>/qubo-proxy. HLS children must point back to the
          // externally reachable HTTPS /functions/v1 route or browsers block
          // them as mixed content.
          const rewritten = rewriteHlsPlaylist(
            playlistText,
            target,
            publicGatewayUrl || request.url,
          );
          bytes = new TextEncoder().encode(rewritten);
          headers.set('Content-Type', 'application/vnd.apple.mpegurl; charset=utf-8');
        } catch (error) {
          const unsupportedChild = error instanceof Error && error.message === 'Unsupported HLS child URL';
          return fail(502,
            unsupportedChild ? 'PROXY_HLS_CHILD_UNSUPPORTED' : 'PROXY_HLS_PLAYLIST_INVALID',
            unsupportedChild
              ? 'The live playlist references an unsupported child resource.'
              : 'The live server returned a non-HLS response.',
            unsupportedChild ? {
              resourceOrigin: error.resourceOrigin,
              resourcePath: error.resourcePath,
            } : {});
        }
      } else {
        const type = upstream.headers.get('content-type');
        if (type) headers.set('Content-Type', type);
      }
      // fetch transparently decompresses gzip. Do not copy encoding/length headers.
      return new Response([204, 205, 304].includes(upstream.status) ? null : bytes,
        {status: upstream.status, headers});
    } catch {
      return fail(controller.signal.aborted ? 504 : 502,
        controller.signal.aborted ? 'PROXY_UPSTREAM_TIMEOUT' : 'PROXY_UPSTREAM_UNAVAILABLE',
        controller.signal.aborted ? 'Qubo did not respond before the gateway timeout.' : 'The gateway could not reach Qubo.');
    } finally { clearTimeout(timer); }
  };
}
