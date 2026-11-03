/*
 * Already signed in.
 * Checks the saved session and offers to continue or go to the dashboard.
 */
(function () {
    'use strict';

    var Auth = window.PIAAuth;

    async function sessionVerdict() {
        try {
            var user = await sb.auth.getUser();
            if (user.error) {
                var status = Number(user.error.status || 0);
                if (
                    status === 401 ||
                    status === 403 ||
                    /session.*(missing|not found)|invalid.*(jwt|token)|jwt expired/i.test(
                        String(user.error.message || user.error.name || '')
                    )
                ) {
                    return 'invalid';
                }
                return 'unknown';
            }
            if (!user.data || !user.data.user) {
                return 'invalid';
            }
        } catch (err) {
            return 'unknown';
        }

        if (
            typeof isSessionCurrentOnServer === 'function' &&
            (await isSessionCurrentOnServer()) === false
        ) {
            return 'invalid';
        }
        return 'valid';
    }

    async function forgetDeadSession() {
        try {
            await Promise.race([
                sb.auth.signOut({ scope: 'local' }),
                new Promise(function (resolve) {
                    setTimeout(resolve, 3000);
                })
            ]);
        } catch (err) {}
        if (typeof clearLocalSession === 'function') {
            clearLocalSession();
        }
    }

    function goStraightToDashboard(email, role) {
        var query;
        try {
            query = new URL(window.PIA_ENTRY_URL || window.location.href).searchParams;
        } catch (err) {
            return false;
        }
        if (query.has('stay') || query.has('signin') || query.has('reason')) {
            return false;
        }

        var now = Date.now();
        try {
            var last = Number(sessionStorage.getItem('pia_straight_to_dashboard') || 0);
            if (now - last < 10000) {
                return false;
            }
            sessionStorage.setItem('pia_straight_to_dashboard', String(now));
        } catch (err) {}

        try {
            localStorage.setItem('pia_user_email', email);
        } catch (err) {}
        if (role === 'admin') {
            window.location.replace('admin/html/admin-dashboard.html');
        } else if (role === 'teacher') {
            window.location.replace('teacher/html/teacher-dashboard.html');
        } else {
            window.location.replace('student/html/waiting-room.html');
        }
        return true;
    }

    async function offerResume() {
        var root = document.documentElement;
        var session = null;

        try {
            session = (await sb.auth.getSession()).data.session;
        } catch (err) {}

        if (session && (await sessionVerdict()) === 'invalid') {
            await forgetDeadSession();
            session = null;
        }

        if (!session) {
            root.removeAttribute('data-session');
            return;
        }
        root.setAttribute('data-session', 'in');

        var email = (session.user && session.user.email) || '';
        var role = null;
        try {
            var roleRes = await sb.from('profiles').select('role').eq('email', email).maybeSingle();
            if (!roleRes.error && roleRes.data) {
                role = Auth.normalizeRole(roleRes.data.role);
            }
        } catch (err) {}

        if (role && goStraightToDashboard(email, role)) {
            return;
        }

        var finale = $('.finale-sub');
        if (finale) {
            finale.textContent =
                'You are signed in. Continue to the activities available to your account.';
        }
        var heroCopy = $('.drop-sub');
        if (heroCopy) {
            heroCopy.textContent =
                'Continue to your dashboard and the activities available to your account.';
        }

        $$('[data-auth-open="signin"]').forEach(function (btn) {
            var label = btn.querySelector('.cta-label') || btn;
            label.textContent = btn.getAttribute('data-resume-label') || 'Continue to dashboard';
            btn.addEventListener(
                'click',
                function (event) {
                    event.stopImmediatePropagation();
                    if (!role) {
                        Auth.toast(
                            'Dashboard unavailable',
                            'Your account role could not be verified. Check your connection and reload.',
                            'danger'
                        );
                        return;
                    }

                    try {
                        localStorage.setItem('pia_user_email', email);
                    } catch (err) {}
                    if (role === 'admin') {
                        window.location.replace('admin/html/admin-dashboard.html');
                    } else if (role === 'teacher') {
                        window.location.replace('teacher/html/teacher-dashboard.html');
                    } else {
                        window.location.replace('student/html/waiting-room.html');
                    }
                },
                true
            );
        });

        $$(
            '.hero-cta .cta-quiet[data-auth-open="signin"], .finale-actions .cta-quiet[data-auth-open="signin"]'
        ).forEach(function (btn) {
            btn.classList.remove('cta-quiet');
            btn.classList.add('cta-primary');
            var glyph = btn.querySelector('.cta-orb use');
            if (glyph) {
                glyph.setAttribute('href', '/assets/icons-landing.svg#i-arrow-right');
            }
        });
    }
    Auth.offerResume = offerResume;
})();
