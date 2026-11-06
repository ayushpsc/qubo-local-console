import { createProxy } from './handler.mjs';

const supabaseUrl = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/$/, '');

Deno.serve(createProxy({
  allowedOrigins: (Deno.env.get('QUBO_ALLOWED_ORIGINS') ??
    'http://localhost:5173,http://localhost:8080')
    .split(',').map((value: string) => value.trim()).filter(Boolean),
  googleHomeCapture: Deno.env.get('GOOGLE_HOME_CAPTURE_B64') ?? '',
  firebaseProjectId: Deno.env.get('FIREBASE_PROJECT_ID') ?? '',
  publicGatewayUrl: supabaseUrl
    ? `${supabaseUrl}/functions/v1/qubo-proxy`
    : '',
}));
