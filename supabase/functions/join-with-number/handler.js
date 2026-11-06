// The rules of the student-number door, with no I/O of their own: everything
// that touches a database or the Auth Admin API arrives through `Deps`.
// index.js wires Deps to Supabase; tests/sim wires the same handler to an
// in-memory store, so the use cases can be rehearsed without a database.
//
//   { action: 'lookup', number }   -> { ok, name, section }
//   { action: 'enter',  number }   -> { ok, status: 'let_in', email, token_hash }
//
// The flow: while a class is open the admin calls the names and marks each
// student present or absent. A student types the number and confirms the name
// (lookup), then enters. Only a student marked present gets a one-time sign-in
// token, and only ONCE: the first entry is free. A second try (a closed browser,
// another computer, a classmate typing the number) is refused and counted on that
// student's row; only the admin's "Let back in" lets it through again.
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
    notReady: 'Class is not open yet. Please wait.',
    notFound: 'We could not find you in this class today. Tell your admin.',
    alreadyIn:
        'You are already signed in. If you lost your connection, tell your admin to let you back in.',
    late: 'The session has already started. Tell your admin.',
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
    const action = String(body.action ?? '');
    if (action !== 'lookup' && action !== 'enter')
        return { status: 400, body: { error: 'Unknown action.' } };
    const key = normalizeNumber(body.number);
    if (!NUMBER_PATTERN.test(key)) return { status: 404, body: { error: MESSAGES.notFound } };
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
        const seenEmail = student.email.trim().toLowerCase();
        const seen = await deps.attendanceFor(student.section, seenEmail);
        if (seen === 'entered') {
            // Refused at the name step already: count it so the admin sees the try on the row.
            await deps.noteReentry(student.section, seenEmail);
            return { status: 409, body: { error: MESSAGES.alreadyIn } };
        }
        // The attendance was locked when the first stage opened: a Present student who never entered is out.
        // A try after the lock is counted too, so the admin sees it in the bell and can let the student in.
        // The waiting page asks again every few seconds with quiet: those asks are not counted again.
        if (seen === 'late') {
            if (!body.quiet) await deps.noteReentry(student.section, seenEmail);
            return { status: 403, body: { error: MESSAGES.late, waiting: true } };
        }
        return {
            status: 200,
            body: { ok: true, name: student.full_name ?? '', section: student.section }
        };
    }
    // ---- enter ----------------------------------------------------------------
    const email = student.email.trim().toLowerCase();
    const mark = await deps.attendanceFor(student.section, email);
    // Same words and same status as an unknown number: the reply says nothing about which it was.
    if (mark === 'none' || mark === 'absent')
        return { status: 404, body: { error: MESSAGES.notFound } };
    if (mark === 'late') {
        if (!body.quiet) await deps.noteReentry(student.section, email);
        return { status: 403, body: { error: MESSAGES.late, waiting: true } };
    }
    // Only the first entry goes through. A second try is refused and counted for the admin.
    if (mark === 'entered') {
        await deps.noteReentry(student.section, email);
        return { status: 409, body: { error: MESSAGES.alreadyIn } };
    }
    const firstEntry = await deps.claimEntry(student.section, email);
    if (!firstEntry) {
        await deps.noteReentry(student.section, email);
        return { status: 409, body: { error: MESSAGES.alreadyIn } };
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
