/*
 * Signed in already.
 * A visitor with a saved session never sees the landing page: they go straight to their
 * dashboard (or the waiting room for a student) before anything is painted.
 */
(function () {
    'use strict';

    if (!/\/(index\.html)?$/.test(window.location.pathname)) {
        return;
    }
    var query = new URLSearchParams(window.location.search);
    var hash = window.location.hash;
    if (
        query.has('reason') ||
        query.has('signin') ||
        query.has('token_hash') ||
        query.has('error_description') ||
        /access_token|error_description/.test(hash)
    ) {
        return;
    }

    function hasSession(store) {
        try {
            for (var i = 0; i < store.length; i++) {
                if (/^sb-.+-auth-token$/.test(store.key(i) || '')) {
                    return true;
                }
            }
        } catch (err) {}
        return false;
    }
    if (!hasSession(localStorage) && !hasSession(sessionStorage)) {
        return;
    }

    var role = '';
    try {
        role = localStorage.getItem('pia_user_role') || '';
    } catch (err) {}
    if (!role) {
        return;
    }

    // one redirect at a time: if the dashboard sent us straight back, stay put
    try {
        var last = Number(sessionStorage.getItem('pia_straight_to_dashboard') || 0);
        if (Date.now() - last < 3000) {
            return;
        }
        sessionStorage.setItem('pia_straight_to_dashboard', String(Date.now()));
    } catch (err) {}

    document.documentElement.style.visibility = 'hidden';
    window.location.replace(
        role === 'admin'
            ? 'admin/html/admin-dashboard.html'
            : role === 'teacher'
              ? 'teacher/html/teacher-dashboard.html'
              : 'student/html/waiting-room.html'
    );
})();
