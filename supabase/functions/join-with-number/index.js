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
    const forwarded = (req.headers.get('x-forwarded-for') ?? '')
        .split(',')
        .map((p) => p.trim())
        .filter(Boolean);
    const ip = req.headers.get('cf-connecting-ip') ?? forwarded[forwarded.length - 1] ?? 'unknown';
    const nowIso = () => new Date().toISOString();
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
        async countSuccesses(key, sinceMs) {
            const { count } = await admin
                .from('join_attempts')
                .select('id', { count: 'exact', head: true })
                .eq('key', key)
                .eq('ok', true)
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
        async experimentEndedFor(section) {
            const { count } = await admin
                .from('game_closed')
                .select('section', { count: 'exact', head: true })
                .eq('section', section)
                .gte('closed_at', sinceIso());
            return (count ?? 0) > 0;
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
            const { data: ci } = await admin.from('checkins').select('locked_at').eq('id', id).maybeSingle();
            if (ci && ci.locked_at && !data.entered_once) return 'late';
            return 'present';
        },
        async claimEntry(section, email) {
            const id = await openCheckinId(section);
            if (!id) return false;
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
