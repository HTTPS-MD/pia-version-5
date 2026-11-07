// ============================================================================
// PIA -- topic-summary  (Supabase Edge Function, Deno)
// ============================================================================
// The share of the whole class that struggled in each topic, for the teacher, after the admin closed the Game.
// See handler.js for the rules. It uses the same secrets as learning-profile:
//   PIA_ML_URL, PIA_ML_TOKEN, PIA_ALLOWED_ORIGINS   (SUPABASE_URL, SUPABASE_ANON_KEY and
//   SUPABASE_SERVICE_ROLE_KEY are provided automatically)
// Gateway JWT check: leave "Enforce JWT verification" ON.
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
    const deps = {
        // run AS the teacher: the database decides who the teacher is and whether the Game was closed
        closedSection: async (authHeader) => {
            const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_ANON_KEY'), {
                global: { headers: { Authorization: authHeader } },
                auth: { persistSession: false }
            });
            const res = await sb.rpc('teacher_closed_section');
            if (res.error) throw res.error;
            return res.data || null;
        },
        // the anonymous measurements: only the service role can read them
        rows: async (section) => {
            const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), {
                auth: { persistSession: false }
            });
            const res = await sb.rpc('topic_features_for_section', { p_section: section });
            if (res.error) throw res.error;
            return res.data || [];
        }
    };
    return handle(req, env, deps);
});
