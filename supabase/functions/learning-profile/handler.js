// PIA -- learning-profile: the request logic, free of Deno imports so it can be
// tested in Node (tests/learning-profile-edge.cjs). index.js wires it to Supabase.
//
// Flow: student's browser -> THIS function -> pia-ml-api (Cloudflare).
//   1. The student's own token is required. The numbers come from the database
//      (get_learning_features, run AS the student, so the game's guard applies:
//      Control, teachers and signed-out callers are refused).
//   2. Exactly seven numbers are sent to the ML service, picked by name below:
//      no name, email, student id, session id, tutor or group. The token for the
//      ML service lives only in this function's secrets.
//   3. The answer is recorded (record_learning_profile: profile, number of submissions, time, with the student read
//      from the session) so the admin can see it. Only {profile, confidence: null} goes back to the browser (the rule-based tree has no probability). Any failure is a
//      plain error and the page keeps its current wording.
// The browser sends only {session_id}. It cannot send features and cannot send
// "learn": there is nothing in this path that can change the model.
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
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// The profile is read from the last eight submissions, so it waits for half of them. Until then the answer is
// 'average' and the service is not asked (two wrong answers in a row would otherwise mean 0% and struggling).
const MIN_EVENTS = 4;
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
        headers: {
            ...cors(origin, env),
            'Content-Type': 'application/json',
            'Cache-Control': 'no-store'
        }
    });
}
export async function handle(req, env, rpc, fetchFn = fetch, record = async () => {}) {
    const origin = req.headers.get('Origin');
    if (req.method === 'OPTIONS')
        return new Response(null, { status: 204, headers: cors(origin, env) });
    if (req.method !== 'POST') return reply(405, { error: 'POST only.' }, origin, env);
    // Off until both the ML address and its secret are configured.
    if (!env.mlUrl || !env.mlToken) return reply(503, { error: 'Not configured.' }, origin, env);
    const auth = req.headers.get('Authorization') || '';
    if (!auth.startsWith('Bearer ') || auth.length < 20)
        return reply(401, { error: 'Sign in first.' }, origin, env);
    let sessionId = '';
    try {
        const body = await req.json();
        if (!body || typeof body !== 'object' || Object.keys(body).join() !== 'session_id')
            throw new Error('shape');
        sessionId = String(body.session_id);
        if (!UUID.test(sessionId)) throw new Error('uuid');
    } catch (_e) {
        return reply(400, { error: 'Send only {"session_id": "<uuid>"}.' }, origin, env);
    }
    const res = await rpc(auth, sessionId);
    if (res.error || !res.data || typeof res.data !== 'object') {
        return reply(403, { error: 'Not available for this account.' }, origin, env);
    }
    const src = res.data;
    const events = Number(src.events || 0);
    if (events < MIN_EVENTS)
        return reply(200, { profile: 'average', confidence: null, source: 'default' }, origin, env);
    // Pick the seven by name; nothing else is ever forwarded.
    const payload = {};
    for (const k of FEATURES) {
        const v = Number(src.features ? src.features[k] : NaN);
        if (!Number.isFinite(v)) return reply(502, { error: 'Bad features.' }, origin, env);
        payload[k] = v;
    }
    try {
        const ml = await fetchFn(env.mlUrl.replace(/\/+$/, '') + '/predict', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + env.mlToken },
            body: JSON.stringify(payload),
            signal: AbortSignal.timeout(env.timeoutMs || 5000)
        });
        if (!ml.ok) return reply(502, { error: 'Profile service unavailable.' }, origin, env);
        const out = await ml.json();
        // The decision tree answers only the profile; it has no probability, so confidence is always null.
        if (!out || !PROFILES.includes(String(out.profile))) {
            return reply(502, { error: 'Profile service unavailable.' }, origin, env);
        }
        // Keep a record of what the tree answered (the admin screen reads it). A failure here never changes the answer.
        try {
            await record(sessionId, String(out.profile), events);
        } catch (_e) {}
        return reply(
            200,
            { profile: out.profile, confidence: null, source: 'ml' },
            origin,
            env
        );
    } catch (_e) {
        return reply(502, { error: 'Profile service unavailable.' }, origin, env);
    }
}
