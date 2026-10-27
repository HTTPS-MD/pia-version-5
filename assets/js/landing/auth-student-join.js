/*
 * Student sign-in with a student number.
 * Two steps: type the number, confirm the name, then enter.
 */
(function () {
    'use strict';

    var Auth = window.PIAAuth;

    var join = { step: 'number', number: '', name: '', section: '', pending: false };

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

    function setJoinStep(step) {
        join.step = step;
        var confirm = step === 'confirm';
        $('#join-step-code').hidden = confirm;
        $('#join-step-name').hidden = !confirm;

        $('#join-back').hidden = !confirm;
        $('#join-back').textContent = 'No, that is not me';
        $('#si-submit').hidden = false;
        $('#si-submit').textContent = confirm ? 'Yes, that is me' : 'Next';
        $('#signin-title').textContent = confirm ? 'Is this you?' : 'Enter your code';
        $('#signin-sub').textContent = confirm
            ? 'Check the name and section before you continue.'
            : 'Type the number on your school ID.';
    }

    function resetJoin() {
        if (!$('#join-step-code')) {
            return;
        }
        join.number = '';
        join.pending = false;
        $('#join-number').value = '';
        $('#join-who').textContent = '';
        $('#join-section').textContent = '';
        setJoinStep('number');
        Auth.clearFormErrors('signin-form');
        Auth.clearStatus('signin-status');
    }
    Auth.resetJoin = resetJoin;

    function backToNumber(message) {
        setJoinStep('number');
        $('#join-number').value = '';
        Auth.clearFormErrors('signin-form');
        Auth.clearStatus('signin-status');
        if (typeof message === 'string' && message) {
            Auth.setStatus('signin-status', message, 'error');
        }
        $('#join-number').focus();
    }
    Auth.backToNumber = backToNumber;

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
                backToNumber(message);
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

    async function handleStudentJoin(event) {
        event.preventDefault();
        if (join.pending || $('#si-submit').disabled) {
            return;
        }
        Auth.clearFormErrors('signin-form');
        Auth.clearStatus('signin-status');

        var overlay = $('#modal-signin');
        var version = overlay.dataset.authVersion || '0';
        var current = function () {
            return (
                overlay.classList.contains('is-open') &&
                (overlay.dataset.authVersion || '0') === version
            );
        };

        if (join.step === 'number') {
            var number = $('#join-number').value.replace(/\D/g, '');
            if (
                !Auth.setFieldError(
                    'join-number',
                    number.length === 11 ? '' : 'Type your code.'
                )
            ) {
                $('#join-number').focus();
                return;
            }
            join.pending = true;
            var release = Auth.setBusy($('#si-submit'), 'Checking…');
            try {
                var found = await joinCall({ action: 'lookup', number: number });
                if (!current()) {
                    return;
                }
                if (!found.ok) {
                    Auth.setStatus(
                        'signin-status',
                        (found.data && found.data.error) ||
                            'Could not check the number. Try again.',
                        'error'
                    );
                    $('#join-number').focus();
                    return;
                }
                join.number = number;
                join.name = found.data.name || '';
                join.section = found.data.section || '';
                $('#join-who').textContent = join.name;
                $('#join-section').textContent = join.section ? 'Section ' + join.section : '';
                setJoinStep('confirm');
            } catch (err) {
                if (current()) {
                    Auth.setStatus(
                        'signin-status',
                        'Can’t reach the server. Check your Wi-Fi, then try again.',
                        'error'
                    );
                }
            } finally {
                join.pending = false;
                release();
                $('#si-submit').textContent = join.step === 'confirm' ? 'Yes, that is me' : 'Next';
            }
            return;
        }

        join.pending = true;
        var releaseEnter = Auth.setBusy($('#si-submit'), 'Entering…');
        try {
            var entered = await joinCall({ action: 'enter', number: join.number });
            if (!current()) {
                return;
            }
            if (!entered.ok) {
                Auth.setStatus(
                    'signin-status',
                    (entered.data && entered.data.error) || 'Could not let you in. Try again.',
                    'error'
                );
                return;
            }
            await enterWithToken(entered.data.token_hash);
        } catch (err) {
            if (current()) {
                Auth.setStatus(
                    'signin-status',
                    'Can’t reach the server. Check your Wi-Fi, then try again.',
                    'error'
                );
            }
        } finally {
            join.pending = false;
            releaseEnter();
            $('#si-submit').textContent = join.step === 'confirm' ? 'Yes, that is me' : 'Next';
        }
    }
    Auth.handleStudentJoin = handleStudentJoin;
})();
