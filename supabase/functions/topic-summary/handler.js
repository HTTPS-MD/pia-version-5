// PIA -- topic-summary: the share of the whole class that struggled in each topic, for the teacher, AFTER the admin
// closed the Game for the teacher's section. Free of Deno imports so it can be tested in Node; index.js wires it.
//
// Flow: teacher's browser -> THIS function.
//   1. The teacher's own token is required. teacher_closed_section() (run AS the teacher) answers the teacher's section
//      only when the Game was closed for it; otherwise nothing is computed and nothing is shown.
//   2. With the service role the function reads the anonymous measurements of every student of that section on each
//      topic (topic_features_for_section: no name, no e-mail). Each student x topic that has at least MIN_EVENTS
//      submissions is classified by the same decision tree as the learning profile (the ml-service Worker).
//   3. Only percentages of the WHOLE class go back: struggling students / students in the class. No name, no count per
//      student, no student number.
const MIN_EVENTS = 4; // the same minimum as the learning profile
const TOPICS = [1, 2, 3];
const FEATURES = [
    'recent_accuracy',
    'average_attempts',
    'hint_rate',
    'average_response_time',
    'correct_response_efficiency',
    'consecutive_correct',
    'consecutive_wrong'
];
const PROFILES = ['struggling', 'average', 'outstanding'];
function cors(origin, env) {
    const h = { Vary: 'Origin' };
    if (origin && env.allowedOrigins.includes(origin)) {
        h['Access-Control-Allow-Origin'] = origin;
        h['Access-Control-Allow-Headers'] = 'authorization, x-client-info, apikey, content-type';
        h['Access-Control-Allow-Methods'] = 'POST, OPTIONS';
    }
    return h;
}
function reply(status, body, origin, env) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { ...cors(origin, env), 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }
    });
}
async function classify(features, env, fetchFn) {
    const payload = {};
    for (const k of FEATURES) {
        const v = Number(features ? features[k] : NaN);
        if (!Number.isFinite(v)) throw new Error('bad features');
        payload[k] = v;
    }
    const ml = await fetchFn(env.mlUrl.replace(/\/+$/, '') + '/predict', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + env.mlToken },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(env.timeoutMs || 5000)
    });
    if (!ml.ok) throw new Error('service');
    const out = await ml.json();
    if (!out || !PROFILES.includes(String(out.profile))) throw new Error('profile');
    return String(out.profile);
}
// deps: { closedSection(auth) -> string|null, rows(section) -> [{student_no, topic, events, features}] }
export async function handle(req, env, deps, fetchFn = fetch) {
    const origin = req.headers.get('Origin');
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(origin, env) });
    if (req.method !== 'POST') return reply(405, { error: 'POST only.' }, origin, env);
    if (!env.mlUrl || !env.mlToken) return reply(503, { error: 'Not configured.' }, origin, env);
    const auth = req.headers.get('Authorization') || '';
    if (!auth.startsWith('Bearer ') || auth.length < 20) return reply(401, { error: 'Sign in first.' }, origin, env);
    let section = null;
    try {
        section = await deps.closedSection(auth);
    } catch (_e) {
        return reply(403, { error: 'Not available for this account.' }, origin, env);
    }
    // The Game has not been closed for this teacher's section: nothing is computed, nothing is shown.
    if (!section) return reply(200, { closed: false }, origin, env);
    let rows;
    try {
        rows = await deps.rows(section);
    } catch (_e) {
        return reply(502, { error: 'Summary unavailable.' }, origin, env);
    }
    const students = new Set((rows || []).map((r) => r.student_no));
    // A section with no students has nothing to show.
    if (students.size === 0) return reply(200, { closed: true, hidden: true }, origin, env);
    const struggling = { 1: 0, 2: 0, 3: 0 };
    try {
        const todo = (rows || []).filter((r) => TOPICS.includes(Number(r.topic)) && Number(r.events) >= MIN_EVENTS);
        // a few at a time, so a class of 40 does not open 120 connections at once
        for (let i = 0; i < todo.length; i += 8) {
            const part = await Promise.all(
                todo.slice(i, i + 8).map(async (r) => ({ topic: Number(r.topic), profile: await classify(r.features, env, fetchFn) }))
            );
            for (const p of part) if (p.profile === 'struggling') struggling[p.topic] += 1;
        }
    } catch (_e) {
        return reply(502, { error: 'Summary unavailable.' }, origin, env);
    }
    const topics = TOPICS.map((t) => ({ topic: t, percent: Math.round((struggling[t] / students.size) * 100) }));
    return reply(200, { closed: true, hidden: false, topics }, origin, env);
}
