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
