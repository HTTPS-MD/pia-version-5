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
        try {
            var last = Number(sessionStorage.getItem('pia_straight_to_dashboard') || 0);
            if (Date.now() - last < 3000) {
                return 'stay';
            }
            sessionStorage.setItem('pia_straight_to_dashboard', String(Date.now()));
        } catch (err) {}

        try {
            localStorage.setItem('pia_user_email', email);
            localStorage.setItem('pia_user_role', role);
        } catch (err) {}
        if (role === 'admin') {
            window.location.replace('admin/html/admin-dashboard.html');
        } else if (role === 'teacher') {
            window.location.replace('teacher/html/teacher-dashboard.html');
        } else {
            window.location.replace('student/html/waiting-room.html');
        }
        return 'go';
    }

    function wait(ms) {
        return new Promise(function (resolve) {
            setTimeout(resolve, ms);
        });
    }

    async function findRole(email) {
        for (var attempt = 0; attempt < 3; attempt++) {
            try {
                var res = await sb.from('profiles').select('role').eq('email', email).maybeSingle();
                if (!res.error && res.data) {
                    return Auth.normalizeRole(res.data.role);
                }
            } catch (err) {}
            await wait(600);
        }
        return null;
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

        var email = (session.user && session.user.email) || '';
        var role = await findRole(email);
        var outcome = role ? goStraightToDashboard(email, role) : null;
        if (outcome === 'go') {
            return;
        }

        root.removeAttribute('data-session');
        if (!role) {
            Auth.toast(
                'Couldn\u2019t confirm your account',
                'Check your connection, then sign in again.',
                'danger'
            );
        }
    }
    Auth.offerResume = offerResume;
})();
