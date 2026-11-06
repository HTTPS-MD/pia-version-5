/*
 * Student sign-in with a student number.
 * One step: type the number and join. The door answers the same way to every refusal, so nothing about who is
 * registered or whether the session started leaks. A refused student waits (quietly asking again) until the
 * admin lets them in, and then goes straight in.
 */
(function () {
    'use strict';

    var Auth = window.PIAAuth;

    var join = { pending: false };
    var REFUSED = 'Can’t let you in yet. Tell your admin.';

    function joinCall(payload) {
        return sb.functions
            .invoke('join-with-number', { body: payload })
            .then(async function (res) {
                if (!res.error) {
                    return { ok: true, data: res.data || {} };
                }
                var data = {};
                try {
                    data = await res.error.context.json();
                } catch (err) {}
                return {
                    ok: false,
                    status: (res.error.context && res.error.context.status) || 0,
                    data: data
                };
            });
    }
    Auth.joinCall = joinCall;

    var waitTimer = null;
    function stopWaiting() {
        clearTimeout(waitTimer);
        waitTimer = null;
        var line = $('#join-error-wait');
        if (line) {
            line.hidden = true;
        }
    }

    function resetJoin() {
        if (!$('#join-number')) {
            return;
        }
        join.pending = false;
        $('#join-number').value = '';
        Auth.clearFormErrors('signin-form');
        Auth.clearStatus('signin-status');
    }
    Auth.resetJoin = resetJoin;

    function showJoinError(message) {
        stopWaiting();
        Auth.closeModal('modal-signin', true);
        $('#join-error-text').textContent = message;
        Auth.openModal('modal-join-error');
    }
    Auth.showJoinError = showJoinError;

    async function enterWithToken(tokenHash, ui) {
        ui = ui || {};
        var overlay = $('#modal-signin');
        var version = overlay.dataset.authVersion || '0';
        var current =
            ui.current ||
            function () {
                return (
                    overlay.classList.contains('is-open') &&
                    (overlay.dataset.authVersion || '0') === version
                );
            };
        var fail =
            ui.fail ||
            function (message) {
                showJoinError(message);
            };

        try {
            sessionStorage.setItem('pia_student_tab', '1');
        } catch (err) {}

        var session = await sb.auth.verifyOtp({ token_hash: tokenHash, type: 'magiclink' });
        if (session.error) {
            session = await sb.auth.verifyOtp({ token_hash: tokenHash, type: 'email' });
        }
        if (!current()) {
            if (!session.error) {
                await sb.auth.signOut({ scope: 'local' });
            }
            return;
        }
        if (session.error || !session.data || !session.data.user) {
            fail('Could not open your session. Please try again.');
            return;
        }

        var email = session.data.user.email;
        var profileRes = await sb.from('profiles').select('*').eq('email', email).maybeSingle();
        if (!current()) {
            await sb.auth.signOut({ scope: 'local' });
            return;
        }
        if (profileRes.error || !profileRes.data) {
            await sb.auth.signOut({ scope: 'local' });
            fail('This account is not set up yet. Please tell your admin.');
            return;
        }

        var profile = profileRes.data;
        var role = Auth.normalizeRole(profile.role);
        if (role !== 'student') {
            await sb.auth.signOut({ scope: 'local' });
            fail(Auth.areaMismatch('student', role) || 'This door is for students.');
            return;
        }

        try {
            localStorage.setItem('pia_user_email', email);
            localStorage.setItem('pia_user_role', role);
        } catch (err) {}

        var check = await Auth.claimSeat(email, profile, role);
        if (!current()) {
            await sb.auth.signOut({ scope: 'local' });
            return;
        }
        if (!check.allowed) {
            await sb.auth.signOut({ scope: 'local' });
            try {
                localStorage.removeItem('pia_user_email');
                localStorage.removeItem('pia_user_role');
            } catch (err) {}
            fail(check.reason);
            return;
        }

        await Auth.routeAfterSignIn(
            profile,
            role,
            ui.report ||
                function (text, tone) {
                    Auth.setStatus('signin-status', text, tone);
                }
        );
    }
    Auth.enterWithToken = enterWithToken;

    // Refused: say so, wait, and keep asking quietly (the door counts only the first try, for the admin's bell)
    // until the admin lets the student in. Then the student goes straight in. Stops when the window is closed.
    function showJoinWaiting(message, number, ui) {
        showJoinError(message);
        $('#join-error-wait').hidden = false;
        var until = Date.now() + 10 * 60000;
        (function tick() {
            waitTimer = setTimeout(async function () {
                var box = $('#modal-join-error');
                if (!box.classList.contains('is-open') || Date.now() > until) {
                    stopWaiting();
                    return;
                }
                try {
                    var again = await joinCall({ action: 'enter', number: number, quiet: true });
                    if (!box.classList.contains('is-open')) {
                        stopWaiting();
                        return;
                    }
                    if (again.ok) {
                        stopWaiting();
                        Auth.closeModal('modal-join-error', true);
                        if (ui.working) {
                            ui.working();
                        }
                        await enterWithToken(again.data.token_hash, ui);
                        return;
                    }
                    var data = again.data || {};
                    if (!data.waiting) {
                        showJoinError(data.error || 'Could not let you in. Try again.');
                        return;
                    }
                } catch (err) {}
                tick();
            }, 5000);
        })();
    }

    // One door for both boxes (the first screen and the sign-in window).
    async function joinWithNumber(number, ui) {
        var res = await joinCall({ action: 'enter', number: number });
        if (!res.ok) {
            var data = res.data || {};
            var message = data.error || 'Could not let you in. Try again.';
            if (data.waiting) {
                showJoinWaiting(message, number, ui);
            } else {
                showJoinError(message);
            }
            return false;
        }
        await enterWithToken(res.data.token_hash, ui);
        return true;
    }
    Auth.joinWithNumber = joinWithNumber;

    async function handleStudentJoin(event) {
        event.preventDefault();
        if (join.pending || $('#si-submit').disabled) {
            return;
        }
        Auth.clearFormErrors('signin-form');
        Auth.clearStatus('signin-status');

        var number = $('#join-number').value.replace(/\D/g, '');
        if (number.length !== 11) {
            showJoinError(REFUSED);
            return;
        }
        var overlay = $('#modal-signin');
        var version = overlay.dataset.authVersion || '0';
        join.pending = true;
        var release = Auth.setBusy($('#si-submit'), 'Entering…');
        try {
            await joinWithNumber(number, {
                // after a wait the window is opened again, which is a new version of it
                working: function () {
                    Auth.openModal('modal-signin');
                    version = overlay.dataset.authVersion || '0';
                    Auth.setBusy($('#si-submit'), 'Entering…');
                },
                current: function () {
                    return (
                        overlay.classList.contains('is-open') &&
                        (overlay.dataset.authVersion || '0') === version
                    );
                }
            });
        } catch (err) {
            showJoinError('Can’t reach the server. Check your Wi-Fi, then try again.');
        } finally {
            join.pending = false;
            release();
            $('#si-submit').textContent = 'Join';
        }
    }
    Auth.handleStudentJoin = handleStudentJoin;
})();
