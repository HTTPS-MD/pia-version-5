/*
 * Session guard.
 * Watches that the sign-in is still valid, and ends the session cleanly when it is not.
 */
const SESSION_CHECK_MS = 10 * 1000;

let sessionCheckTimerId = null;

let sessionCheckInFlight = false;

let sessionGuardOff = false;

let piaSessionEnded = false;

let piaUserSigningOut = false;

function tokenSessionId(token) {
    try {
        const part = String(token).split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
        const json = JSON.parse(atob(part + '='.repeat((4 - (part.length % 4)) % 4)));
        return json.session_id || 'unknown';
    } catch (e) {
        return 'unknown';
    }
}

async function localSessionId() {
    try {
        const { data } = await supabaseClient.auth.getSession();
        const session = data && data.session;
        return session ? tokenSessionId(session.access_token) : null;
    } catch (e) {
        return undefined;
    }
}

async function fetchSessionStatus() {
    if (!window.supabaseClient) return null;
    try {
        const { data, error } = await supabaseClient.rpc('check_student_session');
        if (error) {
            if (isMissingFunction(error)) stopSessionGuard();
            return null;
        }
        const status = data && data.status;
        return ['active', 'replaced', 'revoked', 'none'].indexOf(status) === -1 ? null : status;
    } catch (e) {
        return null;
    }
}

async function checkStudentSession() {
    if (piaSessionEnded || sessionGuardOff || sessionCheckInFlight) return;
    if (document.hidden || navigator.onLine === false) return;

    sessionCheckInFlight = true;
    try {
        const before = await localSessionId();
        if (before === null) {
            endStudentSession('ended');
            return;
        }

        const status = await fetchSessionStatus();
        if (status === null || status === 'active') return;

        const after = await localSessionId();
        if (after !== null && after !== before) return;

        endStudentSession(status === 'none' ? 'ended' : status);
    } finally {
        sessionCheckInFlight = false;
    }
}

function stopSessionGuard() {
    sessionGuardOff = true;
    clearInterval(sessionCheckTimerId);
}

function startSessionGuard() {
    if (sessionCheckTimerId !== null || piaSessionEnded || !window.supabaseClient) return;

    sessionCheckTimerId = setInterval(checkStudentSession, SESSION_CHECK_MS);
    checkStudentSession();

    document.addEventListener('visibilitychange', () => {
        if (!document.hidden) checkStudentSession();
    });
    window.addEventListener('online', checkStudentSession);

    supabaseClient.auth.onAuthStateChange((event) => {
        if (event !== 'SIGNED_OUT' || piaUserSigningOut) return;
        setTimeout(() => endStudentSession('ended'), 0);
    });
}

const SESSION_ENDED_COPY = {
    replaced: {
        title: 'Signed in on another device',
        text: 'Your account was logged in from another device. You have been securely logged out here.',
        note: 'To keep working on this device instead, sign in again. The other device will be signed out.'
    },
    revoked: {
        title: 'You’ve been signed out',
        text: 'Your admin or the study team signed this account out. You have been securely logged out here.',
        note: ''
    },
    ended: {
        title: 'Your session has ended',
        text: 'For your security, you have been signed out on this device.',
        note: ''
    }
};

const STAFF_SIGNIN_PATH = '/index.html';

async function isSessionCurrentOnServer() {
    if (!window.supabaseClient) return null;
    try {
        const { data, error } = await supabaseClient.rpc('jwt_is_current');
        if (error) return null;
        return data === true ? true : data === false ? false : null;
    } catch (e) {
        return null;
    }
}

function staffSignInUrl(reason) {
    return (
        STAFF_SIGNIN_PATH +
        '?signin=staff' +
        (reason ? '&reason=' + encodeURIComponent(reason) : '')
    );
}

async function endStaffSession(reason) {
    if (piaSessionEnded) return;
    piaSessionEnded = true;

    stopSessionGuard();
    if (staffWatch) clearInterval(staffWatch.timer);
    clearInterval(presenceTimerId);
    clearTimeout(idleTimeoutId);
    clearInterval(idleCountdownId);
    removeAllChannels();

    try {
        await Promise.race([
            supabaseClient.auth.signOut({ scope: 'local' }),
            new Promise((resolve) => setTimeout(resolve, 3000))
        ]);
    } catch (e) {}
    clearLocalSession();
    window.location.replace(staffSignInUrl(reason || 'ended'));
}

let staffWatch = null;

function startStaffSessionWatch() {
    if (staffWatch || piaSessionEnded || !window.supabaseClient) return;
    staffWatch = { timer: null, busy: false };

    const check = async () => {
        if (piaSessionEnded || staffWatch.busy) return;
        if (document.hidden || navigator.onLine === false) return;
        staffWatch.busy = true;
        try {
            const { data } = await supabaseClient.auth.getSession();
            if (!data || !data.session) {
                endStaffSession('ended');
                return;
            }
            if ((await isSessionCurrentOnServer()) === false) endStaffSession('revoked');
        } catch (e) {
        } finally {
            staffWatch.busy = false;
        }
    };

    staffWatch.timer = setInterval(check, SESSION_CHECK_MS);
    document.addEventListener('visibilitychange', () => {
        if (!document.hidden) check();
    });
    window.addEventListener('focus', check);
    window.addEventListener('online', check);

    supabaseClient.auth.onAuthStateChange((event) => {
        if (event !== 'SIGNED_OUT' || piaUserSigningOut) return;
        setTimeout(() => endStaffSession('ended'), 0);
    });

    check();
}

function clearLocalSession() {
    try {
        const deviceId = localStorage.getItem('pia_device_id');
        const theme = localStorage.getItem('pia_theme');
        localStorage.clear();
        sessionStorage.clear();
        if (deviceId) localStorage.setItem('pia_device_id', deviceId);
        if (theme) localStorage.setItem('pia_theme', theme);
    } catch (e) {}
}

async function endStudentSession(reason) {
    if (piaSessionEnded) return;
    piaSessionEnded = true;

    stopSessionGuard();
    clearInterval(presenceTimerId);
    clearTimeout(idleTimeoutId);
    clearInterval(idleCountdownId);
    const idleModal = document.getElementById('pia-idle-modal');
    if (idleModal) idleModal.remove();
    removeAllChannels();

    // (2) Say why, before any network call can stall.
    showSessionEnded(SESSION_ENDED_COPY[reason] ? reason : 'ended');
    window.dispatchEvent(new CustomEvent('pia:session-ended', { detail: { reason } }));

    try {
        await Promise.race([
            supabaseClient.auth.signOut({ scope: 'local' }),
            new Promise((resolve) => setTimeout(resolve, 4000))
        ]);
    } catch (e) {}
    clearLocalSession();
}

function showSessionEnded(reason) {
    if (document.getElementById('pia-session-ended')) return;
    const copy = SESSION_ENDED_COPY[reason];

    Array.prototype.forEach.call(document.body.children, (node) => {
        if (node.tagName !== 'SCRIPT') node.inert = true;
    });
    if (document.activeElement && document.activeElement.blur) document.activeElement.blur();

    document.body.classList.remove('opacity-0');

    piaDialog({
        id: 'pia-session-ended',
        role: 'alertdialog',
        zIndex: 'var(--z-lockout)',
        title: copy.title,
        text: copy.text,
        note: copy.note,
        actions: [
            {
                label: 'Okay',
                primary: true,
                onClick: (btn) => {
                    btn.disabled = true;
                    btn.textContent = 'Opening sign-in…';
                    clearLocalSession();
                    window.location.replace('/index.html');
                }
            }
        ]
    });
}
