import {spawnSync} from 'node:child_process';
const gateway = process.argv[2] || process.env.QUBO_PROXY_URL || '';
const firebaseProjectId = process.env.FIREBASE_PROJECT_ID || '';
const firebaseWebApiKey = process.env.FIREBASE_WEB_API_KEY || '';
const missing = [
  ['QUBO_PROXY_URL', gateway],
  ['FIREBASE_PROJECT_ID', firebaseProjectId],
  ['FIREBASE_WEB_API_KEY', firebaseWebApiKey],
].filter(([, value]) => !value).map(([name]) => name);
if (missing.length) {
  console.error(`Set the required build configuration: ${missing.join(', ')}`);
  process.exit(1);
}
try {
  const url = new URL(gateway);
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) throw new Error();
} catch {
  console.error('Use the HTTPS function endpoint without query parameters.');
  process.exit(1);
}
const result = spawnSync(process.env.FLUTTER_BIN || 'flutter', [
  'build', 'web', '--release',
  `--dart-define=QUBO_PROXY_URL=${gateway}`,
  `--dart-define=FIREBASE_PROJECT_ID=${firebaseProjectId}`,
  `--dart-define=FIREBASE_WEB_API_KEY=${firebaseWebApiKey}`,
], {stdio: 'inherit', shell: false});
if (result.error) console.error('Flutter was not found. Put it on PATH or set FLUTTER_BIN to its executable.');
process.exit(result.status ?? 1);
