// ============================================================================
// PIA -- join-with-number  (Supabase Edge Function, Deno)
// ============================================================================
// The student door for the computer lab: a student number.
// The roll is taken face to face, outside the system, and students who are not there are removed from
// the session. When the admin presses Start, every student on the roster can enter. The rules live in
// handler.js (and are rehearsed in tests/sim); this file only connects them to Supabase.
//
// HOW A SESSION IS OPENED: for a student on the roster, the Auth Admin API
// makes a one-time sign-in token for the EXISTING account and hands it to the
// browser that asked, once; the browser redeems it with verifyOtp. Everything
// after that (profile lookup, claim_student_session, routing) is the normal
// pipeline, so RLS, stages and the one-device rule behave as after a password
// sign-in.
//
// WHY AN EDGE FUNCTION: minting a session for another user needs the
// service-role key, which must never reach a browser.
//
// WHAT THIS DOES NOT PROVE: who is typing. A student number is known to a
// student's classmates. What limits it: only a student on the roster gets in while the session is
// running, a student gets in once (the second try is refused, counted in
// attendance_marks.refused_count, and only the admin's Let back in allows it again), and after End
// a student who never entered is refused.
//
// A student who never activated has a profile but no auth user: the function
// creates it (email confirmed, a random password nobody knows) the first time
// they are let in.
//
// DEPLOY (needs migrations 0052 and 0058)
//   supabase functions deploy join-with-number --no-verify-jwt
//   The caller is an anonymous visitor, so JWT verification is OFF here.
// ============================================================================
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { handleJoin } from './handler.js';
const CORS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
function send(status, body) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { ...CORS, 'Content-Type': 'application/json' }
    });
}
const like = (value) => value.replace(/[\\%_]/g, (c) => '\\' + c);
Deno.serve(async (req) => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
    if (req.method !== 'POST') return send(405, { error: 'Method not allowed.' });
    const url = Deno.env.get('SUPABASE_URL');
    const serviceKey =
        Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY');
    if (!url || !serviceKey) return send(500, { error: 'The join service is not configured.' });
    let body;
    try {
        body = await req.json();
    } catch {
        return send(400, { error: 'The request body must be JSON.' });
    }
    const admin = createClient(url, serviceKey, {
        auth: { persistSession: false, autoRefreshToken: false }
    });
    // Prefer the address the edge itself saw. The FIRST x-forwarded-for entry can be written by the
    // caller, so fall back to the LAST one, which the platform's own proxy appended.
    const forwarded = (req.headers.get('x-forwarded-for') ?? '')
        .split(',')
        .map((p) => p.trim())
        .filter(Boolean);
    const ip = req.headers.get('cf-connecting-ip') ?? forwarded[forwarded.length - 1] ?? 'unknown';
    const nowIso = () => new Date().toISOString();
    // "Today" is the calendar day in Philippine time (UTC+8, no daylight saving). Same rule as the database
    // (pia_current_checkin): at 12:00 AM the section goes back to needing a new Start.
    const sinceIso = (nowMs = Date.now()) => {
        const manila = new Date(nowMs + 8 * 3600 * 1000);
        manila.setUTCHours(0, 0, 0, 0);
        return new Date(manila.getTime() - 8 * 3600 * 1000).toISOString();
    };
    const openCount = async (section) => {
        let q = admin
            .from('checkins')
            .select('id', { count: 'exact', head: true })
            .gte('started_at', sinceIso());
        if (section) q = q.eq('section', section);
        const { count } = await q;
        return count ?? 0;
    };
    // The newest session of the section started today, open or ended: after End only a student who
    // entered before (and was let back in) can still come in.
    const openCheckinId = async (section) => {
        const { data } = await admin
            .from('checkins')
            .select('id')
            .eq('section', section)
            .gte('started_at', sinceIso())
            .order('started_at', { ascending: false })
            .limit(1);
        return data && data.length ? String(data[0].id) : null;
    };
    const deps = {
        now: () => Date.now(),
        async countFailures(key, sinceMs) {
            const { count } = await admin
                .from('join_attempts')
                .select('id', { count: 'exact', head: true })
                .eq('key', key)
                .eq('ok', false)
                .gte('at', new Date(sinceMs).toISOString());
            return count ?? 0;
        },
        async record(key, ok) {
            await admin.from('join_attempts').insert({ key, ok });
        },
        async findStudent(numberKey) {
            const { data: row } = await admin
                .from('student_numbers')
                .select('email')
                .eq('number_key', numberKey)
                .maybeSingle();
            if (!row) return null;
            const { data: p } = await admin
                .from('profiles')
                .select('email, full_name, section, role')
                .ilike('email', like(String(row.email)))
                .maybeSingle();
            return p
                ? {
                      email: p.email,
                      full_name: p.full_name,
                      section: String(p.section ?? '').trim(),
                      role: p.role
                  }
                : null;
        },
        anyCheckinOpen: async () => (await openCount()) > 0,
        checkinOpenFor: async (section) => (await openCount(section)) > 0,
        async standingFor(section, email) {
            const id = await openCheckinId(section);
            if (!id) return 'none';
            const { data } = await admin
                .from('attendance_marks')
                .select('present, entered_at, entered_once')
                .eq('checkin_id', id)
                .eq('email', email)
                .maybeSingle();
            if (!data) return 'none';
            if (!data.present) return 'absent';
            if (data.entered_at) return 'entered';
            // Locked when the first stage opened: only a student who entered before may still come back in.
            const { data: ci } = await admin.from('checkins').select('locked_at').eq('id', id).maybeSingle();
            if (ci && ci.locked_at && !data.entered_once) return 'late';
            return 'present';
        },
        async claimEntry(section, email) {
            const id = await openCheckinId(section);
            if (!id) return false;
            // One atomic step in the database: Present, not already in, and not locked out.
            const { data, error } = await admin.rpc('pia_claim_entry', { p_checkin: id, p_email: email });
            if (error) throw error;
            return data === true;
        },
        async releaseEntry(section, email) {
            const id = await openCheckinId(section);
            if (id)
                await admin
                    .from('attendance_marks')
                    .update({ entered_at: null })
                    .eq('checkin_id', id)
                    .eq('email', email);
        },
        async noteReentry(section, email) {
            const id = await openCheckinId(section);
            if (!id) return;
            const { data } = await admin
                .from('attendance_marks')
                .select('refused_count')
                .eq('checkin_id', id)
                .eq('email', email)
                .maybeSingle();
            if (data)
                await admin
                    .from('attendance_marks')
                    .update({ refused_count: (data.refused_count ?? 0) + 1 })
                    .eq('checkin_id', id)
                    .eq('email', email);
            // One line in the permanent log for each refused try (it ignores a missing table).
            await admin.from('entry_log').insert({ checkin_id: id, email, kind: 'refused' });
        },
        async ensureAccount(email) {
            const { data: id, error } = await admin.rpc('pia_auth_user_id', { p_email: email });
            if (error) throw error;
            if (id) return;
            const random = crypto.getRandomValues(new Uint8Array(24));
            const password = Array.from(random, (b) => b.toString(16).padStart(2, '0')).join('');
            const { error: createError } = await admin.auth.admin.createUser({
                email,
                password,
                email_confirm: true
            });
            if (createError) throw createError;
        },
        async mintToken(email) {
            const { data, error } = await admin.auth.admin.generateLink({
                type: 'magiclink',
                email
            });
            return error ? null : (data?.properties?.hashed_token ?? null);
        }
    };
    const reply = await handleJoin(body, ip, deps);
    return send(reply.status, reply.body);
});
