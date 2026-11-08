// The rules of the student-number door, with no I/O of their own: everything
// that touches a database or the Auth Admin API arrives through `Deps`.
// index.js wires Deps to Supabase; tests/sim wires the same handler to an
// in-memory store, so the use cases can be rehearsed without a database.
//
//   { action: 'enter', number, quiet? } -> { ok, status: 'let_in', email, token_hash }
//
// The flow: the roll is taken face to face, outside the system. The admin removes students who are not
// there from the session, then presses Start. A student types the number and enters. Only a student on
// the roster gets a one-time sign-in token, and only ONCE: the first entry is free. A second try (a
// closed browser, another computer, a classmate typing the number) is refused and counted on that
// student's row; only the admin's "Let back in" lets it through again. After End, a student who never
// entered is refused like anyone else (no count, nothing to let back in).
//
// EVERY refusal is the same answer (same words, same status, waiting: true): an unknown number, a
// removed student, one after End, one already in, nothing open. Outside the class nobody can tell whether the
// session started or whether a number is registered, and no name is ever sent. A refused student waits and
// asks again with quiet: true (not counted again for the admin's bell) until the admin lets them in.
//
// After the admin ends the experiment for a section, the same refusal applies to everyone in it, with no bell and no count.
//
// A number is accepted once the admin has started a session for the student's section today. While no
// session was started today the answer is the same for every number and no name is read, so nothing
// about the roster leaks.
export const MAX_FAILURES_PER_NUMBER = 5;
export const MAX_FAILURES_PER_IP = 150; // a whole lab (about 40 students) shares one address
// The address can be faked, so it cannot be the only brake: this caps ALL failed tries
// together. A lab of 40 children making typos stays far below it; a script guessing
// numbers does not.
export const MAX_FAILURES_ALL = 200;
export const WINDOW_MS = 10 * 60_000;
// The cap on ALL tries must not let an outsider lock the whole class out. An address that let a
// student in during the last 12 hours (the lab) is "known": the cap on all tries does not apply to
// it, only its own cap of 150. Once the cap is reached, only new addresses are stopped.
export const KNOWN_ADDRESS_MS = 12 * 60 * 60_000;
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
    // A waiting screen asks again every few seconds with quiet: true. Those asks must not use up the tries of the
    // whole class, so they are free, but only for a number that was refused (a real try) in the last 10 minutes.
    // A quiet ask for any other number is an ordinary try. Guessing numbers therefore always costs real tries.
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
    // An unknown number counts as a failed try (the brake against guessing numbers).
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
    // Nothing open anywhere: the same refusal, whatever the number. No name is read, nothing leaks.
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
    // Once the experiment has ended for the section (today), nobody comes in and nothing is counted for the admin's bell.
    if (deps.experimentEndedFor && (await deps.experimentEndedFor(student.section))) return refused;
    const email = student.email.trim().toLowerCase();
    const mark = await deps.standingFor(student.section, email);
    if (mark === 'none' || mark === 'absent') return fail();
    // After End, a student who never entered is refused like anyone else: no bell, nothing to let back in.
    if (mark === 'late') {
        if (!quiet) await deps.record('q:' + key, false);
        return refused;
    }
    // Already in: refused, and counted once for the admin's bell.
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
        // This address let a student in: it is now known (see KNOWN_ADDRESS_MS). A failed note never blocks the entry.
        try {
            await deps.record('ok:ip:' + ip, true);
        } catch {}
        return { status: 200, body: { ok: true, status: 'let_in', email, token_hash: tokenHash } };
    } catch {
        await deps.releaseEntry(student.section, email);
        return { status: 500, body: { error: MESSAGES.server } };
    }
}
