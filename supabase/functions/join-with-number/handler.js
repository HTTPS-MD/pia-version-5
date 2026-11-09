export const MAX_FAILURES_PER_NUMBER = 5;
export const MAX_FAILURES_PER_IP = 150;
export const MAX_FAILURES_ALL = 200;
export const WINDOW_MS = 10 * 60_000;
export const KNOWN_ADDRESS_MS = 12 * 60 * 60_000;
export const MESSAGES = {
    refused: 'Can’t let you in yet. Tell your admin.',
    throttled: 'Too many tries. Please wait a few minutes, or tell your admin.',
    server: 'Something went wrong. Please try again.'
};
export function normalizeNumber(raw) {
    return String(raw ?? '')
        .replace(/\D/g, '')
        .slice(0, 24);
}
export const NUMBER_PATTERN = /^\d{11}$/;
export async function handleJoin(body, ip, deps) {
    if (String(body.action ?? '') !== 'enter')
        return { status: 400, body: { error: 'Unknown action.' } };
    const refused = { status: 403, body: { error: MESSAGES.refused, waiting: true } };
    const key = normalizeNumber(body.number);
    if (!NUMBER_PATTERN.test(key)) return refused;
    const since = deps.now() - WINDOW_MS;
    const quiet = body.quiet === true && (await deps.countFailures('q:' + key, since)) > 0;
    const [byNumber, byIp, byAll] = await Promise.all([
        deps.countFailures('n:' + key, since),
        deps.countFailures('ip:' + ip, since),
        deps.countFailures('all', since)
    ]);
    const knownAddress =
        byAll >= MAX_FAILURES_ALL &&
        (await deps.countSuccesses('ok:ip:' + ip, deps.now() - KNOWN_ADDRESS_MS)) > 0;
    if (
        byNumber >= MAX_FAILURES_PER_NUMBER ||
        byIp >= MAX_FAILURES_PER_IP ||
        (byAll >= MAX_FAILURES_ALL && !knownAddress)
    ) {
        return { status: 429, body: { error: MESSAGES.throttled } };
    }
    const fail = async () => {
        if (!quiet) {
            await Promise.all([
                deps.record('n:' + key, false),
                deps.record('ip:' + ip, false),
                deps.record('all', false),
                deps.record('q:' + key, false)
            ]);
        }
        return refused;
    };
    if (!(await deps.anyCheckinOpen())) {
        if (!quiet) await deps.record('q:' + key, false);
        return refused;
    }
    const student = await deps.findStudent(key);
    const role = String(student?.role ?? 'student')
        .trim()
        .toLowerCase();
    const allowed =
        !!student &&
        role !== 'admin' &&
        role !== 'teacher' &&
        (await deps.checkinOpenFor(student.section));
    if (!student || !allowed) return fail();
    if (deps.experimentEndedFor && (await deps.experimentEndedFor(student.section))) return refused;
    const email = student.email.trim().toLowerCase();
    const mark = await deps.standingFor(student.section, email);
    if (mark === 'none' || mark === 'absent') return fail();
    if (mark === 'late') {
        if (!quiet) await deps.record('q:' + key, false);
        return refused;
    }
    if (mark === 'entered') {
        if (!quiet) {
            await deps.noteReentry(student.section, email);
            await deps.record('q:' + key, false);
        }
        return refused;
    }
    const firstEntry = await deps.claimEntry(student.section, email);
    if (!firstEntry) {
        if (!quiet) {
            await deps.noteReentry(student.section, email);
            await deps.record('q:' + key, false);
        }
        return refused;
    }
    try {
        await deps.ensureAccount(email);
        const tokenHash = await deps.mintToken(email);
        if (!tokenHash) {
            await deps.releaseEntry(student.section, email);
            return { status: 500, body: { error: MESSAGES.server } };
        }
        try {
            await deps.record('ok:ip:' + ip, true);
        } catch {}
        return { status: 200, body: { ok: true, status: 'let_in', email, token_hash: tokenHash } };
    } catch {
        await deps.releaseEntry(student.section, email);
        return { status: 500, body: { error: MESSAGES.server } };
    }
}
