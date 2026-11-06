import {test} from 'node:test';
import assert from 'node:assert/strict';
import {gzipSync, gunzipSync} from 'node:zlib';
import {createProxy, allowedTarget, findLiveMasterUrl, parseGoogleHomeCapture, rewriteHlsPlaylist, verifyFirebaseIdToken} from '../../supabase/functions/qubo-proxy/handler.mjs';
const login = 'https://srvcapp.platform.quboworld.com/sms/api/v1/sp/tenant/user/phone/login';
const emailLogin = 'https://srvcapp.platform.quboworld.com/sms/api/v1/sp/tenant/user/login?system=CS';
const refresh = 'https://srvcapp.platform.quboworld.com/sms/api/v1/sp/tenant/users/user-id/auth/refresh';
const events = 'https://srvcapp.platform.quboworld.com/control-monitor/api/v1/sp/tenant/lastEvent';
const signed = 'https://north-az1-s3.cloud.airtel.in:10446/ar-nz-hero-iot-prod-ai-event/unit/image.jpeg?X-Amz-Signature=a%2Fb&X-Amz-Date=20261024';
const transaction = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const pushRequest = 'https://srvcapp.platform.quboworld.com/push-pull/request';
const pushStatus = `https://srvcapp.platform.quboworld.com/push-pull/transaction/${transaction}`;
const media = `https://heroiot-prod-push-pull.s3.ap-south-1.amazonaws.com/sdCardMedia--${transaction}--/tmp/mnt/sdcard0/camera/clip.mp4?X-Amz-Signature=a%2Fb&X-Amz-Date=20261024T092355Z&X-Amz-Expires=300`;
const googleHome = 'https://googlehomefoyer-pa.googleapis.com/google.internal.home.foyer.v1.HomeControlService/UpdateTraits';
const liveMaster = 'http://13.235.191.60:1935/hero-iot-live/HLS_22222222-2222-4222-8222-222222222222_93/playlist.m3u8?wowzatoken=signed%2Bvalue';
const origin = 'http://localhost:5173';
const firebaseHeaders = {authorization: 'Bearer valid-firebase-token'};
const firebaseOptions = {
  firebaseProjectId: 'qubo-local-console-test',
  verifyFirebaseTokenImpl: async (token, project) => {
    assert.equal(token, 'valid-firebase-token');
    assert.equal(project, 'qubo-local-console-test');
    return {sub: 'firebase-user'};
  },
};
const captureFrame = new Uint8Array([0, 0, 0, 0, 1, 8]);
const captureHeaders = [
  'POST /google.internal.home.foyer.v1.HomeControlService/UpdateTraits HTTP/2',
  'host: googlehomefoyer-pa.googleapis.com:443',
  'authorization: Bearer configured-google-token',
  'x-goog-ext-202964622-bin: YWJjZGVmZ2g=',
  'foyer-gha-environment: aWprbG1ub3A=',
  'accept-language: en-IN',
  'grpc-timeout: 9993228u',
  '', '',
].join('\r\n');
const configuredCapture = Buffer.concat([Buffer.from(captureHeaders, 'latin1'), Buffer.from(captureFrame)]).toString('base64');
function req(target, {method = 'GET', headers = {}, body} = {}) {
  const url = new URL('https://project.supabase.co/functions/v1/qubo-proxy');
  if (target) url.searchParams.set('url', target);
  return new Request(url, {method, headers: {origin, ...headers}, body});
}
function actionReq({headers = {}, body} = {}) {
  const url = new URL('https://project.supabase.co/functions/v1/qubo-proxy');
  url.searchParams.set('action', 'google-home-live');
  return new Request(url, {method: 'POST', headers: {origin, ...headers}, body});
}
const sessionHeaders = {'subscriber-key': 'user-token', 'user-uuid': 'user-id'};

test('configured localhost origins accept every required custom header', async () => {
  for (const from of [origin, 'http://localhost:8080', 'http://localhost:5173']) {
    const res = await createProxy()(req(login, {method: 'OPTIONS', headers: {origin: from}}));
    assert.equal(res.status, 204);
    assert.equal(res.headers.get('access-control-allow-origin'), from);
    assert.match(res.headers.get('access-control-allow-headers'), /subscriber-key/);
    assert.match(res.headers.get('access-control-allow-headers'), /range/);
    assert.match(res.headers.get('access-control-allow-headers'), /authorization/);
    assert.match(res.headers.get('access-control-allow-headers'), /x-google-authorization/);
    assert.match(res.headers.get('access-control-expose-headers'), /X-Qubo-Proxy/);
  }
});
test('a deployment can explicitly allow its hosted console origin', async () => {
  const hostedOrigin = 'https://console.example.test';
  const res = await createProxy({allowedOrigins: [hostedOrigin]})(
    req(login, {method: 'OPTIONS', headers: {origin: hostedOrigin}}),
  );
  assert.equal(res.status, 204);
  assert.equal(res.headers.get('access-control-allow-origin'), hostedOrigin);
});
test('Google Home replay forwards only the captured gRPC context', async () => {
  const body = new Uint8Array([0, 0, 0, 0, 1, 8]);
  let forwarded;
  const handler = createProxy({fetchImpl: async (url, options) => {
    forwarded = {url, options};
    return new Response(new TextEncoder().encode(`\0\0${liveMaster}\0`), {
      headers: {'content-type': 'application/grpc'},
    });
  }});
  const res = await handler(req(googleHome, {method: 'POST', headers: {
    'content-type': 'application/octet-stream',
    'x-google-authorization': 'Bearer fresh-google-token',
    'x-google-ext': 'YWJjZGVmZ2g=',
    'x-google-environment': 'aWprbG1ub3A=',
    'x-google-grpc-timeout': '9999999u',
  }, body}));
  assert.equal(res.status, 200);
  assert.equal(forwarded.url, googleHome);
  assert.equal(forwarded.options.headers.get('authorization'), 'Bearer fresh-google-token');
  assert.equal(forwarded.options.headers.get('subscriber-key'), null);
  assert.equal(forwarded.options.headers.get('x-goog-ext-202964622-bin'), 'YWJjZGVmZ2g=');
  assert.equal(forwarded.options.headers.get('grpc-accept-encoding'), 'identity');
  assert.deepEqual(new Uint8Array(forwarded.options.body), body);
});
test('Google Home replay requires context headers and stays on the exact method', async () => {
  const missing = await createProxy()(req(googleHome, {method: 'POST', body: new Uint8Array([0])}));
  assert.equal(missing.status, 401);
  assert.equal((await missing.json()).code, 'PROXY_GOOGLE_AUTH_REQUIRED');
  assert.equal(allowedTarget(`${googleHome}/other`, 'POST'), null);
  assert.equal(allowedTarget(googleHome, 'GET'), null);
});
test('configured Home capture is parsed and never supplied by the public bundle', () => {
  const parsed = parseGoogleHomeCapture(configuredCapture);
  assert.equal(parsed.authorization, 'Bearer configured-google-token');
  assert.equal(parsed.grpcTimeout, '9993228u');
  assert.deepEqual(parsed.body, captureFrame);
  for (const invalid of ['', 'not-base64', Buffer.from('GET / HTTP/2\r\n\r\nhello').toString('base64')]) {
    assert.throws(() => parseGoogleHomeCapture(invalid));
  }
});
test('configured live action validates Firebase then replays the server capture', async () => {
  const calls = [];
  const handler = createProxy({
    ...firebaseOptions,
    googleHomeCapture: configuredCapture,
    fetchImpl: async (url, options) => {
      calls.push({url, options});
      assert.equal(url, googleHome);
      assert.equal(options.headers.get('authorization'), 'Bearer configured-google-token');
      assert.notEqual(options.headers.get('authorization'), 'Bearer browser-injected-token');
      assert.deepEqual(new Uint8Array(options.body), captureFrame);
      return new Response(new TextEncoder().encode(`\0\0${liveMaster}\0`), {
        headers: {'content-type': 'application/grpc'},
      });
    },
  });
  const res = await handler(actionReq({headers: {
    ...firebaseHeaders,
    'x-google-authorization': 'Bearer browser-injected-token',
  }}));
  assert.equal(res.status, 200);
  assert.equal(calls.length, 1);
  assert.equal((await res.json()).masterUrl, liveMaster);
});
test('configured live action turns empty or expired Google responses into readable errors', async () => {
  for (const scenario of [
    {headers: {}, code: 'PROXY_LIVE_RESPONSE_EMPTY', status: 502},
    {headers: {'grpc-status': '16'}, code: 'PROXY_GOOGLE_AUTH_EXPIRED', status: 401},
  ]) {
    const handler = createProxy({
      ...firebaseOptions,
      googleHomeCapture: configuredCapture,
      fetchImpl: async () => new Response(null, {headers: scenario.headers}),
    });
    const res = await handler(actionReq({headers: {
      ...firebaseHeaders,
    }}));
    assert.equal(res.status, scenario.status);
    const data = await res.json();
    assert.equal(data.code, scenario.code);
    assert.equal(data.responseBytes, 0);
  }
});
test('live master extraction rejects unrelated and unsupported URLs', () => {
  assert.equal(findLiveMasterUrl(new TextEncoder().encode(`\0${liveMaster}\0`)), liveMaster);
  assert.equal(findLiveMasterUrl(new TextEncoder().encode('\0https://example.com/playlist.m3u8\0')), null);
  assert.equal(findLiveMasterUrl(new Uint8Array()), null);
});
test('configured live action and HLS media require a valid Firebase ID token', async () => {
  let calls = 0;
  const missing = await createProxy()(actionReq({headers: sessionHeaders}));
  assert.equal(missing.status, 503);
  assert.equal((await missing.json()).code, 'PROXY_LIVE_PRESET_MISSING');

  const handler = createProxy({
    ...firebaseOptions,
    googleHomeCapture: configuredCapture,
    fetchImpl: async (url) => {
      calls++;
      if (String(url).includes('/playlist.m3u8')) {
        return new Response('#EXTM3U\n#EXT-X-VERSION:3');
      }
      return new Response(new TextEncoder().encode(`\0${liveMaster}\0`));
    },
  });
  const wrong = await handler(actionReq());
  assert.equal(wrong.status, 401);
  assert.equal((await wrong.json()).code, 'PROXY_FIREBASE_AUTH_REQUIRED');
  assert.equal(calls, 0);
  const invalid = await handler(actionReq({headers: {
    authorization: 'Bearer invalid-firebase-token',
  }}));
  assert.equal(invalid.status, 401);
  assert.equal((await invalid.json()).code, 'PROXY_FIREBASE_AUTH_INVALID');
  assert.equal(calls, 0);

  const playlistMissing = await handler(req(liveMaster));
  assert.equal(playlistMissing.status, 401);
  assert.equal((await playlistMissing.json()).code, 'PROXY_FIREBASE_AUTH_REQUIRED');
  const playlist = await handler(req(liveMaster, {headers: firebaseHeaders}));
  assert.equal(playlist.status, 200);
  assert.equal(calls, 1);
});
test('Firebase ID token verifier checks signature, issuer, audience and expiry', async () => {
  const pair = await crypto.subtle.generateKey(
    {name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256'},
    true, ['sign', 'verify'],
  );
  const publicJwk = await crypto.subtle.exportKey('jwk', pair.publicKey);
  const encode = (value) => Buffer.from(typeof value === 'string' ? value : JSON.stringify(value))
    .toString('base64url');
  const now = 1793097000000;
  const header = encode({alg: 'RS256', kid: 'test-firebase-key', typ: 'JWT'});
  const payload = encode({
    aud: 'qubo-local-console-test', iss: 'https://securetoken.google.com/qubo-local-console-test',
    sub: 'firebase-user', iat: now / 1000 - 5, auth_time: now / 1000 - 10,
    exp: now / 1000 + 3600, email: 'viewer@example.test',
  });
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5', pair.privateKey, new TextEncoder().encode(`${header}.${payload}`),
  );
  const token = `${header}.${payload}.${Buffer.from(signature).toString('base64url')}`;
  const claims = await verifyFirebaseIdToken(token, 'qubo-local-console-test', {
    now,
    fetchImpl: async () => new Response(JSON.stringify({
      keys: [{...publicJwk, kid: 'test-firebase-key', alg: 'RS256', use: 'sig'}],
    }), {headers: {'cache-control': 'public, max-age=3600'}}),
  });
  assert.equal(claims.sub, 'firebase-user');
  await assert.rejects(() => verifyFirebaseIdToken(token, 'another-project', {now}));
});
test('HLS playlists rewrite relative chunklists, segments and URI attributes through HTTPS gateway', async () => {
  const gateway = 'https://project.supabase.co/functions/v1/qubo-proxy?url=old';
  const text = [
    '#EXTM3U',
    '#EXT-X-STREAM-INF:BANDWIDTH=256000',
    'chunklist_w123_tkdZHVtbXktdG9rZW4=.m3u8?sourceDevice=device&sessionId=session',
    '#EXT-X-KEY:METHOD=AES-128,URI="media.key"',
  ].join('\n');
  const rewritten = rewriteHlsPlaylist(text, liveMaster, gateway);
  assert.match(rewritten, /https:\/\/project\.supabase\.co\/functions\/v1\/qubo-proxy\?url=/);
  assert.match(decodeURIComponent(rewritten), /chunklist_w123_tkdZHVtbXktdG9rZW4=\.m3u8/);
  assert.match(decodeURIComponent(rewritten), /media\.key/);

  const handler = createProxy({fetchImpl: async () => new Response(text, {
    headers: {'content-type': 'application/vnd.apple.mpegurl'},
  })});
  const res = await handler(req(liveMaster));
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /application\/vnd\.apple\.mpegurl/);
  assert.match(await res.text(), /project\.supabase\.co/);
});
test('HLS rewrites use the configured public URL instead of Supabase internal routing', async () => {
  const internal = new URL('http://project.supabase.co/qubo-proxy');
  internal.searchParams.set('url', liveMaster);
  const handler = createProxy({
    publicGatewayUrl: 'https://project.supabase.co/functions/v1/qubo-proxy',
    fetchImpl: async () => new Response(
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=250000\nchunklist_w1_tkdZHVtbXk==.m3u8?sessionId=session',
      {headers: {'content-type': 'application/vnd.apple.mpegurl'}},
    ),
  });
  const res = await handler(new Request(internal, {headers: {origin}}));
  assert.equal(res.status, 200);
  const body = await res.text();
  assert.match(body, /https:\/\/project\.supabase\.co\/functions\/v1\/qubo-proxy\?url=/);
  assert.doesNotMatch(body, /http:\/\/project\.supabase\.co\/qubo-proxy/);
});
test('empty live playlists are retryable and malformed/unsupported manifests are distinct', async () => {
  const empty = await createProxy({fetchImpl: async () => new Response('')})(req(liveMaster));
  assert.equal(empty.status, 503);
  assert.equal(empty.headers.get('retry-after'), '2');
  assert.equal((await empty.json()).code, 'PROXY_HLS_NOT_READY');

  const malformed = await createProxy({fetchImpl: async () => new Response('<html>starting</html>')})(req(liveMaster));
  assert.equal(malformed.status, 502);
  assert.equal((await malformed.json()).code, 'PROXY_HLS_PLAYLIST_INVALID');

  const unsupported = await createProxy({fetchImpl: async () => new Response(
    '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="https://example.com/media.key"\nmedia_1.ts',
  )})(req(liveMaster));
  assert.equal(unsupported.status, 502);
  const unsupportedData = await unsupported.json();
  assert.equal(unsupportedData.code, 'PROXY_HLS_CHILD_UNSUPPORTED');
  assert.equal(unsupportedData.resourceOrigin, 'https://example.com');
  assert.equal(unsupportedData.resourcePath, '/media.key');
});
test('HLS transport accepts same-session keys and nested media but rejects escapes', async () => {
  const segment = liveMaster.replace('playlist.m3u8', 'media_42.ts');
  const handler = createProxy({fetchImpl: async (url, options) => {
    assert.equal(url, segment);
    assert.equal(options.headers.get('authorization'), null);
    return new Response(new Uint8Array([0x47, 0, 0]), {headers: {'content-type': 'binary/octet-stream'}});
  }});
  const res = await handler(req(segment));
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-type'), 'video/mp2t');
  assert.deepEqual(new Uint8Array(await res.arrayBuffer()), new Uint8Array([0x47, 0, 0]));
  for (const target of [
    liveMaster.replace('playlist.m3u8', 'chunklist_w123_tkdZHVtbXktdG9rZW4=.m3u8'),
    liveMaster.replace('playlist.m3u8', 'media_w123_tkdZHVtbXktdG9rZW4==_1.ts'),
    liveMaster.replace('playlist.m3u8', 'keys/media.key'),
    liveMaster.replace('playlist.m3u8', 'video/init.mp4'),
    liveMaster.replace('playlist.m3u8', 'audio/rendition.aac'),
  ]) assert.notEqual(allowedTarget(target, 'GET'), null);
  assert.throws(() => rewriteHlsPlaylist(
    '#EXTM3U\n../HLS_11111111-1111-1111-1111-111111111111_1/media.ts',
    liveMaster,
    'https://project.supabase.co/functions/v1/qubo-proxy',
  ), /Unsupported/);
  for (const target of [
    liveMaster.replace('13.235.191.60', '127.0.0.1'),
    liveMaster.replace(':1935', ':80'),
    liveMaster.replace('/hero-iot-live/', '/private/'),
  ]) assert.equal(allowedTarget(target, 'GET'), null);
});
test('OTP login and verification are reachable without Supabase or Qubo JWTs', async () => {
  for (const target of [login, login.replace('/login', '/verify')]) {
    let forwarded;
    const handler = createProxy({fetchImpl: async (url, options) => {
      forwarded = {url, options};
      return new Response('{"uuid":"u"}', {headers: {'content-type': 'application/json'}});
    }});
    const body = JSON.stringify({phone: '9000000000', isdCode: '+91'});
    const res = await handler(req(target, {method: 'POST', headers: {'app-id': 'app', 'content-type': 'application/json'}, body}));
    assert.equal(res.status, 200);
    assert.equal(new TextDecoder().decode(forwarded.options.body), body);
    assert.match(forwarded.options.headers.get('user-agent'), /^Qubo\/29/);
    assert.equal(forwarded.options.headers.get('origin'), null);
    assert.equal(res.headers.get('x-qubo-proxy'), 'upstream');
  }
});
test('email login forwards the qubopy request without requiring a Qubo token', async () => {
  const body = JSON.stringify({
    username: 'owner@example.test', email: 'owner@example.test', password: 'secret',
    deviceAttribute: 'Apple iPhone15,5',
  });
  let forwarded;
  const handler = createProxy({fetchImpl: async (url, options) => {
    forwarded = {url, options};
    return new Response('{"accessToken":"access","refreshToken":"refresh","uuid":"user-id"}',
      {headers: {'content-type': 'application/json'}});
  }});
  const res = await handler(req(emailLogin, {method: 'POST', headers: {
    'app-id': 'com.hero.iot', 'source-device-id': 'installation', source: 'USER',
    'token-type': 'USER', 'content-type': 'application/json',
  }, body}));
  assert.equal(res.status, 200);
  assert.equal(forwarded.url, emailLogin);
  assert.equal(new TextDecoder().decode(forwarded.options.body), body);
  assert.equal(forwarded.options.headers.get('app-id'), 'com.hero.iot');
  assert.equal(forwarded.options.headers.get('authorization'), null);
});
test('token refresh forwards bearer and subscriber credentials', async () => {
  const body = JSON.stringify({accessToken: 'user-token', refreshToken: 'refresh-token'});
  const handler = createProxy({fetchImpl: async (url, options) => {
    assert.equal(url, refresh);
    assert.equal(options.headers.get('authorization'), 'Bearer user-token');
    assert.equal(options.headers.get('subscriber-key'), 'user-token');
    assert.equal(options.headers.get('user-uuid'), 'user-id');
    assert.equal(new TextDecoder().decode(options.body), body);
    return new Response('{"accessToken":"new-token"}', {headers: {'content-type': 'application/json'}});
  }});
  const res = await handler(req(refresh, {method: 'POST', headers: {
    ...sessionHeaders, authorization: 'Bearer user-token', 'content-type': 'application/json',
  }, body}));
  assert.equal(res.status, 200);
});
test('authenticated application requests forward caller credentials, not Supabase credentials', async () => {
  const handler = createProxy({fetchImpl: async (_, options) => {
    assert.equal(options.headers.get('subscriber-key'), 'user-token');
    assert.equal(options.headers.get('user-uuid'), 'user-id');
    assert.equal(options.headers.get('authorization'), 'Bearer user-token');
    assert.equal(options.headers.get('apikey'), null);
    return new Response('[]');
  }});
  const res = await handler(req(events, {method: 'PUT', headers: {...sessionHeaders, authorization: 'Bearer user-token', apikey: 'anon'}, body: '[]'}));
  assert.equal(res.status, 200);
});
test('captured push-pull request and transaction routes are narrowly allowed', async () => {
  const body = JSON.stringify({files: [{file: '/tmp/mnt/sdcard0/camera/clip.mp4'}]});
  for (const [target, method] of [[pushRequest, 'POST'], [pushStatus, 'GET']]) {
    let forwarded;
    const handler = createProxy({fetchImpl: async (url, options) => {
      forwarded = {url, options};
      return new Response('{}', {headers: {'content-type': 'application/json'}});
    }});
    const res = await handler(req(target, {method, headers: sessionHeaders, body: method === 'POST' ? body : undefined}));
    assert.equal(res.status, 200);
    assert.equal(forwarded.url, target);
    assert.equal(forwarded.options.headers.get('subscriber-key'), 'user-token');
  }
  assert.equal(allowedTarget(pushRequest, 'GET'), null);
  assert.equal(allowedTarget(`${pushStatus}/extra`, 'GET'), null);
});
test('signed snapshot query is preserved exactly and no account credentials reach storage', async () => {
  const bytes = new Uint8Array([255, 216, 255, 0, 1]);
  const handler = createProxy({fetchImpl: async (url, options) => {
    assert.equal(url, signed);
    for (const name of ['subscriber-key', 'user-uuid', 'cookie', 'authorization', 'apikey', 'origin']) assert.equal(options.headers.get(name), null);
    return new Response(bytes, {headers: {'content-type': 'binary/octet-stream'}});
  }});
  const res = await handler(req(signed, {headers: {...sessionHeaders, cookie: 'secret'}}));
  assert.deepEqual(new Uint8Array(await res.arrayBuffer()), bytes);
  assert.match(res.headers.get('cache-control'), /no-store/);
});
test('push-pull video streams byte ranges as video/mp4 without account credentials', async () => {
  const bytes = new Uint8Array([0, 0, 0, 24]);
  const handler = createProxy({fetchImpl: async (url, options) => {
    assert.equal(url, media);
    assert.equal(options.headers.get('range'), 'bytes=0-3');
    for (const name of ['subscriber-key', 'user-uuid', 'cookie', 'authorization', 'apikey', 'origin']) assert.equal(options.headers.get(name), null);
    return new Response(bytes, {status: 206, headers: {
      'content-type': 'binary/octet-stream',
      'content-range': 'bytes 0-3/100',
      'accept-ranges': 'bytes',
      'content-length': '4',
    }});
  }});
  const res = await handler(req(media, {headers: {...sessionHeaders, range: 'bytes=0-3'}}));
  assert.equal(res.status, 206);
  assert.equal(res.headers.get('content-type'), 'video/mp4');
  assert.equal(res.headers.get('content-range'), 'bytes 0-3/100');
  assert.equal(res.headers.get('accept-ranges'), 'bytes');
  assert.deepEqual(new Uint8Array(await res.arrayBuffer()), bytes);
});
test('gateway errors are marked separately from upstream 401 and 403 responses', async () => {
  const missing = await createProxy()(req(events, {method: 'PUT', body: '[]'}));
  assert.equal(missing.status, 401);
  assert.equal(missing.headers.get('x-qubo-proxy'), 'gateway');
  assert.equal((await missing.json()).code, 'PROXY_AUTH_REQUIRED');
  for (const status of [401, 403]) {
    const res = await createProxy({fetchImpl: async () => new Response('{"code":"ERR_AUTH_001"}', {status})})(req(events, {method: 'PUT', headers: sessionHeaders, body: '[]'}));
    assert.equal(res.status, status);
    assert.equal(res.headers.get('x-qubo-proxy'), 'upstream');
    assert.equal(res.headers.get('access-control-allow-origin'), origin);
  }
});
test('unapproved origins and targets are blocked before forwarding', async () => {
  let count = 0;
  const handler = createProxy({fetchImpl: async () => { count++; return new Response(''); }});
  assert.equal((await handler(req(login, {headers: {origin: 'https://untrusted.test'}}))).status, 403);
  for (const url of ['http://169.254.169.254/', 'https://example.com/', 'https://srvcapp.platform.quboworld.com.evil.test/', 'https://srvcapp.platform.quboworld.com/not-an-api']) {
    assert.equal((await handler(req(url))).status, 400);
  }
  assert.equal(allowedTarget(signed, 'PUT'), null);
  assert.equal(allowedTarget(media.replace('X-Amz-Signature', 'Unsigned'), 'GET'), null);
  assert.equal(count, 0);
});
test('redirects cannot move credentials or signed URLs to another host', async () => {
  const res = await createProxy({fetchImpl: async (_, options) => {
    assert.equal(options.redirect, 'manual');
    return new Response(null, {status: 302, headers: {location: 'https://example.com'}});
  }})(req(login, {method: 'POST', body: '{}'}));
  assert.equal(res.status, 502);
  assert.equal(res.headers.get('location'), null);
});
test('decompressed fetch bodies do not retain gzip or content-length headers', async () => {
  const decoded = gunzipSync(gzipSync(Buffer.from('image-bytes')));
  const res = await createProxy({fetchImpl: async () => new Response(decoded, {headers: {'content-encoding': 'gzip', 'content-length': '50'}})})(req(signed));
  assert.equal(await res.text(), 'image-bytes');
  assert.equal(res.headers.get('content-encoding'), null);
  assert.equal(res.headers.get('content-length'), null);
});
test('network failures and deadline timeouts return readable gateway errors', async () => {
  const broken = await createProxy({fetchImpl: async () => {throw new Error('secret upstream details');}})(req(signed));
  assert.equal(broken.status, 502);
  assert.doesNotMatch(await broken.text(), /secret upstream/);
  const timed = await createProxy({timeoutMs: 5, fetchImpl: (_, {signal}) => new Promise((_, reject) => signal.addEventListener('abort', () => reject(new Error('aborted'))))})(req(signed));
  assert.equal(timed.status, 504);
});
test('oversized request bodies do not reach the upstream', async () => {
  const res = await createProxy({fetchImpl: async () => {throw new Error('must not forward');}})(req(login, {method: 'POST', body: 'x'.repeat(256 * 1024 + 1)}));
  assert.equal(res.status, 413);
});

test('north and south snapshots on standard and regional ports preserve signatures and binary bytes', async () => {
  for (const [region, code, regionalPort] of [['north', 'nz', '10446'], ['south', 'sz', '10445']]) {
    for (const port of ['', `:${regionalPort}`]) {
      for (const kind of ['ai', 'vms']) {
        const target = `https://${region}-az1-s3.cloud.airtel.in${port}/ar-${code}-hero-iot-prod-${kind}-event/unit/image.jpeg?X-Amz-Signature=a%2Fb&X-Amz-Date=20261024`;
        const bytes = new Uint8Array([255, 216, 255, 0, 1]);
        const handler = createProxy({fetchImpl: async (url, options) => {
          assert.equal(url, target);
          for (const key of ['subscriber-key', 'user-uuid', 'cookie', 'authorization', 'apikey']) assert.equal(options.headers.get(key), null);
          return new Response(bytes, {headers: {'content-type': 'image/jpeg'}});
        }});
        const res = await handler(req(target, {headers: {...sessionHeaders, authorization: 'Bearer secret'}}));
        assert.equal(res.status, 200);
        assert.equal(res.headers.get('x-qubo-proxy'), 'upstream');
        assert.equal(res.headers.get('access-control-allow-origin'), origin);
        assert.deepEqual(new Uint8Array(await res.arrayBuffer()), bytes);
      }
    }
  }
});
test('storage restrictions still reject region/port mismatches, lookalike hosts and unrelated buckets', () => {
  for (const url of [
    'https://south-az1-s3.cloud.airtel.in:10446/ar-sz-hero-iot-prod-ai-event/u/image.jpeg',
    'https://north-az1-s3.cloud.airtel.in:10445/ar-nz-hero-iot-prod-ai-event/u/image.jpeg',
    'https://south-az1-s3.cloud.airtel.in/ar-nz-hero-iot-prod-ai-event/u/image.jpeg',
    'https://south-az1-s3.cloud.airtel.in.evil.test/ar-sz-hero-iot-prod-ai-event/u/image.jpeg',
    'https://south-az1-s3.cloud.airtel.in/unrelated-bucket/u/image.jpeg',
  ]) assert.equal(allowedTarget(url, 'GET'), null);
});
