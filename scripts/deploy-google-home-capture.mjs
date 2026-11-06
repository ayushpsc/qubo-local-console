import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';

const [requestPath, responsePath, projectRef] = process.argv.slice(2);
if (!requestPath || !responsePath || !projectRef) {
  console.error('Usage: node scripts/deploy-google-home-capture.mjs REQUEST RESPONSE PROJECT_REF');
  process.exit(2);
}

const request = readFileSync(requestPath);
const response = readFileSync(responsePath);
const headerEnd = request.indexOf(Buffer.from('\r\n\r\n'));
const expectedMethod = Buffer.from(
  'POST /google.internal.home.foyer.v1.HomeControlService/UpdateTraits HTTP/2\r\n',
);
if (headerEnd < 0 || !request.subarray(0, expectedMethod.length).equals(expectedMethod)) {
  throw new Error('The request file is not a complete Google Home UpdateTraits capture.');
}
const responseText = response.toString('latin1');
const masterMatch = /http:\/\/13\.235\.191\.60:1935\/hero-iot-live\/HLS_[0-9a-fA-F-]{36}_[0-9]+\/playlist\.m3u8\?[^\x00-\x20"<>]+/i.exec(responseText);
if (!masterMatch) {
  throw new Error('The response does not contain a supported live HLS master URL.');
}

const directory = mkdtempSync(join(tmpdir(), 'qubo-home-capture-'));
const envFile = join(directory, 'capture.env');
try {
  writeFileSync(
    envFile,
    `GOOGLE_HOME_CAPTURE_B64=${request.toString('base64')}\n`,
    {mode: 0o600},
  );
  const result = spawnSync(
    '/usr/bin/supabase',
    ['secrets', 'set', '--project-ref', projectRef, '--env-file', envFile],
    {stdio: 'inherit'},
  );
  if (result.error) throw result.error;
  if (result.status !== 0) process.exitCode = result.status ?? 1;
} finally {
  rmSync(directory, {recursive: true, force: true});
}
