// The rules of the student-number door, with no I/O of their own: everything
// that touches a database or the Auth Admin API arrives through `Deps`.
// index.js wires Deps to Supabase; tests/sim wires the same handler to an
// in-memory store, so the use cases can be rehearsed without a database.
//
//   { action: 'enter', number, quiet? } -> { ok, status: 'let_in', email, token_hash }
//
// The flow: while a class is open the admin calls the names and marks each
// student present or absent. A student types the number and enters. Only a student
// marked present gets a one-time sign-in token, and only ONCE: the first entry is
// free. A second try (a closed browser, another computer, a classmate typing the
// number) is refused and counted on that student's row; only the admin's
// "Let back in" lets it through again.
//
// EVERY refusal is the same answer (same words, same status, waiting: true): an unknown number, an
// absent student, a late one, one already in, nothing open. Outside the class nobody can tell whether the
// session started or whether a number is registered, and no name is ever sent. A refused student waits and
// asks again with quiet: true (not counted again for the admin's bell) until the admin lets them in.
//
// A number is accepted once the admin has taken attendance for the student's
// section today, and it stays accepted after the session is closed, so a student
// marked present who has not entered yet can still come in. While no session was
// opened today the answer is the same for every number and no name is read, so
// nothing about the roster leaks.
export const MAX_FAILURES_PER_NUMBER = 5;
export const MAX_FAILURES_PER_IP = 60; // a whole lab shares one address
// The address can be faked, so it cannot be the only brake: this caps ALL failed tries
// together. A lab of 40 children making typos stays far below it; a script guessing
// numbers does not.
export const MAX_FAILURES_ALL = 200;
export const WINDOW_MS = 10 * 60_000;
export const MESSAGES = {
    refused: 'Can’t let you in yet. Tell your admin.',
    throttled: 'Too many tries. Please wait a few minutes, or tell your admin.',
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
    if (String(body.action ?? '') !== 'enter')
        return { status: 400, body: { error: 'Unknown action.' } };
    const refused = { status: 403, body: { error: MESSAGES.refused, waiting: true } };
    const key = normalizeNumber(body.number);
    if (!NUMBER_PATTERN.test(key)) return refused;
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
    // An unknown number counts as a failed try (the brake against guessing numbers).
    const fail = async () => {
        await Promise.all([
            deps.record('n:' + key, false),
            deps.record('ip:' + ip, false),
            deps.record('all', false)
        ]);
        return refused;
    };
    // Nothing open anywhere: the same refusal, whatever the number. No name is read, nothing leaks.
    if (!(await deps.anyCheckinOpen())) return refused;
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
    const email = student.email.trim().toLowerCase();
    const mark = await deps.attendanceFor(student.section, email);
    if (mark === 'none' || mark === 'absent') return fail();
    // Late (after the lock) or already in: refused, and counted once for the admin's bell.
    if (mark === 'late' || mark === 'entered') {
        if (!body.quiet) await deps.noteReentry(student.section, email);
        return refused;
    }
    const firstEntry = await deps.claimEntry(student.section, email);
    if (!firstEntry) {
        if (!body.quiet) await deps.noteReentry(student.section, email);
        return refused;
    }
    try {
        await deps.ensureAccount(email);
        const tokenHash = await deps.mintToken(email);
        if (!tokenHash) {
            await deps.releaseEntry(student.section, email);
            return { status: 500, body: { error: MESSAGES.server } };
        }
        return { status: 200, body: { ok: true, status: 'let_in', email, token_hash: tokenHash } };
    } catch {
        await deps.releaseEntry(student.section, email);
        return { status: 500, body: { error: MESSAGES.server } };
    }
}
