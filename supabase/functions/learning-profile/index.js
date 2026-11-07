// ============================================================================
// PIA -- learning-profile  (Supabase Edge Function, Deno)
// ============================================================================
// The only place that talks to the pia-ml-api service. The browser calls this
// function; this function calls the ML service. See handler.js for the rules.
//
// SECRETS / SETTINGS (Dashboard -> Edge Functions -> learning-profile -> Secrets,
// or `supabase secrets set`). None of them is ever sent to a browser:
//   PIA_ML_URL      https://pia-ml-api-staging.<your-subdomain>.workers.dev  (staging first)
//   PIA_ML_TOKEN    the same value as the Worker's ML_TOKEN secret
//   PIA_ALLOWED_ORIGINS   comma list, e.g. https://your-pia-site.example,http://127.0.0.1:5504
// Until PIA_ML_URL and PIA_ML_TOKEN are both set the function answers 503 and the
// game simply keeps its default wording.
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
//
// Gateway JWT check: leave "Enforce JWT verification" ON. The function also reads
// the database AS the caller, so the game's own guard applies.
// ============================================================================
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { handle } from './handler.js';
Deno.serve((req) => {
    const env = {
        mlUrl: Deno.env.get('PIA_ML_URL') || '',
        mlToken: Deno.env.get('PIA_ML_TOKEN') || '',
        allowedOrigins: (Deno.env.get('PIA_ALLOWED_ORIGINS') || '')
            .split(',')
            .map((s) => s.trim())
            .filter(Boolean)
    };
    const rpc = async (authHeader, sessionId) => {
        const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_ANON_KEY'), {
            global: { headers: { Authorization: authHeader } },
            auth: { persistSession: false }
        });
        return await sb.rpc('get_learning_features', { p_session_id: sessionId });
    };
    // The record is written with the service role (the browser can never write it). The e-mail is read from the session.
    const record = async (sessionId, profile, events) => {
        const admin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), {
            auth: { persistSession: false }
        });
        await admin.rpc('record_learning_profile', {
            p_session_id: sessionId,
            p_profile: profile,
            p_events: events
        });
    };
    return handle(req, env, rpc, fetch, record);
});
