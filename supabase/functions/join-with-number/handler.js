// The rules of the student-number door, with no I/O of their own: everything
// that touches a database or the Auth Admin API arrives through `Deps`.
// index.js wires Deps to Supabase; tests/sim wires the same handler to an
// in-memory store, so the use cases can be rehearsed without a database.
//
//   { action: 'lookup', number }   -> { ok, name, section }
//   { action: 'enter',  number }   -> { ok, status: 'let_in', email, token_hash }
//
// The flow: while an attendance is open the admin calls the names and marks each
// student present or absent. A student types the number and confirms the name
// (lookup), then enters. Only a student marked present gets a one-time sign-in
// token. A number can enter again (a closed browser, another computer): the newest
// sign-in wins and the older one is signed out by the database. Each re-entry is
// counted so the admin sees it on that student's row.
//
// A number is accepted only while an admin has an attendance open for the
// student's section. While nothing is open, the answer is the same for every
// number and no name is read, so nothing about the roster leaks.
export const MAX_FAILURES_PER_NUMBER = 5;
export const MAX_FAILURES_PER_IP = 60; // a whole lab shares one address
// The address can be faked, so it cannot be the only brake: this caps ALL failed tries
// together. A lab of 40 children making typos stays far below it; a script guessing
// numbers does not.
export const MAX_FAILURES_ALL = 200;
export const WINDOW_MS = 10 * 60_000;
export const MESSAGES = {
    notReady: 'Attendance has not started yet. Please wait.',
    notFound: 'We could not find you in today’s attendance. Tell your admin.',
    throttled: 'Too many tries. Please wait a few minutes, or tell your admin.',
    badNumber: 'Type your 11-digit student number.',
    notMarked: 'Your admin has not marked you present. Tell your admin.',
    server: 'Something went wrong. Please try again.'
};
/** Digits only: "2023-1230142" and "20231230142" are one number. A student number has 11 digits. */
export function normalizeNumber(raw) {
    return String(raw ?? '')
        .replace(/\D/g, '')
        .slice(0, 24);
}
export const NUMBER_PATTERN = /^\d{11}$/;
export async function handleJoin(body, ip, deps) {
    const action = String(body.action ?? '');
    if (action !== 'lookup' && action !== 'enter')
        return { status: 400, body: { error: 'Unknown action.' } };
    const key = normalizeNumber(body.number);
    if (!NUMBER_PATTERN.test(key)) return { status: 422, body: { error: MESSAGES.badNumber } };
    const since = deps.now() - WINDOW_MS;
    const [byNumber, byIp, byAll] = await Promise.all([
        deps.countFailures('n:' + key, since),
        deps.countFailures('ip:' + ip, since),
        deps.countFailures('all', since)
    ]);
    if (
        byNumber >= MAX_FAILURES_PER_NUMBER ||
        byIp >= MAX_FAILURES_PER_IP ||
        byAll >= MAX_FAILURES_ALL
    ) {
        return { status: 429, body: { error: MESSAGES.throttled } };
    }
    const fail = async (reply) => {
        await Promise.all([
            deps.record('n:' + key, false),
            deps.record('ip:' + ip, false),
            deps.record('all', false)
        ]);
        return reply;
    };
    // Nothing open anywhere: say so, whatever the number. No name is read, nothing leaks.
    if (!(await deps.anyCheckinOpen()))
        return { status: 403, body: { error: MESSAGES.notReady, closed: true } };
    const student = await deps.findStudent(key);
    const role = String(student?.role ?? 'student')
        .trim()
        .toLowerCase();
    const allowed =
        !!student &&
        role !== 'admin' &&
        role !== 'teacher' &&
        (await deps.checkinOpenFor(student.section));
    if (!student || !allowed) return fail({ status: 404, body: { error: MESSAGES.notFound } });
    if (action === 'lookup') {
        return {
            status: 200,
            body: { ok: true, name: student.full_name ?? '', section: student.section }
        };
    }
    // ---- enter ----------------------------------------------------------------
    const email = student.email.trim().toLowerCase();
    const mark = await deps.attendanceFor(student.section, email);
    if (mark === 'none' || mark === 'absent')
        return { status: 403, body: { error: MESSAGES.notMarked } };
    // The first entry takes the place; any later one is a re-entry and is only counted.
    const firstEntry = mark === 'present' && (await deps.claimEntry(student.section, email));
    if (!firstEntry) await deps.noteReentry(student.section, email);
    try {
        await deps.ensureAccount(email);
        const tokenHash = await deps.mintToken(email);
        if (!tokenHash) {
            if (firstEntry) await deps.releaseEntry(student.section, email);
            return { status: 500, body: { error: MESSAGES.server } };
        }
        return { status: 200, body: { ok: true, status: 'let_in', email, token_hash: tokenHash } };
    } catch {
        if (firstEntry) await deps.releaseEntry(student.section, email);
        return { status: 500, body: { error: MESSAGES.server } };
    }
}
