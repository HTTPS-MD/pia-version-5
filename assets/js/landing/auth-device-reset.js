/*
 * Sign out other devices.
 * Sends an email code, checks it, and ends the other sessions.
 */
(function () {
    'use strict';

    var Auth = window.PIAAuth;

    var deviceReset = { email: null, area: null };
    Auth.deviceReset = deviceReset;

    var RESEND_COOLDOWN = 60;

    var drTimerId = null;

    function friendlyResetError(error) {
        var raw = String((error && error.message) || '');
        if (/code from your email/i.test(raw)) {
            return 'Confirm it’s you with the code from your email first.';
        }
        if (/signed out/i.test(raw)) {
            return 'This sign-in expired. Send a new code and try again.';
        }
        return 'We couldn’t sign your other devices out. Try again, or ask your teacher.';
    }

    function startDeviceResetCooldown() {
        var btn = $('#dr-resend');
        var left = RESEND_COOLDOWN;
        clearInterval(drTimerId);
        btn.disabled = true;
        btn.textContent = 'Send a new code (' + left + 's)';
        drTimerId = setInterval(function () {
            left -= 1;
            if (left <= 0) {
                clearInterval(drTimerId);
                btn.disabled = false;
                btn.textContent = 'Send a new code';
                return;
            }
            btn.textContent = 'Send a new code (' + left + 's)';
        }, 1000);
    }

    async function sendDeviceResetCode() {
        Auth.clearStatus('device-reset-status');
        var res;
        try {
            res = await sb.auth.signInWithOtp({
                email: deviceReset.email,
                options: {
                    shouldCreateUser: false,
                    emailRedirectTo: emailLinkTo('index.html?flow=device-reset')
                }
            });
        } catch (err) {
            res = {
                error: { message: 'Can’t reach the server. Check your Wi-Fi, then try again.' }
            };
        }

        if (res.error) {
            Auth.setStatus('device-reset-status', Auth.friendlyAuthError(res.error), 'error');
            $('#dr-resend').disabled = false;
            $('#dr-resend').textContent = 'Send a new code';
            return;
        }
        Auth.setStatus('device-reset-status', 'Code sent. It can take a minute to arrive.', 'ok');
        startDeviceResetCooldown();
    }
    Auth.sendDeviceResetCode = sendDeviceResetCode;

    function openDeviceReset() {
        if (!deviceReset.email) {
            return;
        }
        $('#device-reset-form').reset();
        Auth.clearFormErrors('device-reset-form');
        Auth.clearStatus('device-reset-status');
        $('#dr-sent-to').textContent = deviceReset.email;
        Auth.openAuth('device-reset');
        sendDeviceResetCode();
    }
    Auth.openDeviceReset = openDeviceReset;

    async function completeDeviceReset(area, report) {
        var fail = async function (message) {
            await sb.auth.signOut({ scope: 'local' });
            report(message, 'error');
            return false;
        };

        var reset = await sb.rpc('reset_my_devices', { p_device_id: getOrCreateDeviceId() });
        if (reset.error) {
            return fail(friendlyResetError(reset.error));
        }

        var session = (await sb.auth.getSession()).data.session;
        var email = session && session.user ? session.user.email : null;
        if (!email) {
            return fail('This sign-in expired. Send a new code and try again.');
        }

        var profileRes = await sb.from('profiles').select('*').eq('email', email).maybeSingle();
        if (profileRes.error || !profileRes.data) {
            return fail('This account is not set up yet. Please contact the study administrator.');
        }

        var profile = profileRes.data;
        var role = Auth.normalizeRole(profile.role);
        var mismatch = area ? Auth.areaMismatch(area, role) : '';
        if (mismatch) {
            return fail(mismatch);
        }

        if (role === 'student' && typeof claimStudentSession === 'function') {
            var claim = await claimStudentSession();
            if (!claim.allowed && !claim.missing) {
                return fail(claim.reason);
            }
        }

        try {
            localStorage.setItem('pia_user_email', email);
            localStorage.setItem('pia_user_role', role);
        } catch (err) {}

        clearInterval(drTimerId);
        await Auth.routeAfterSignIn(profile, role, report);
        return true;
    }

    async function handleDeviceResetCode(event) {
        event.preventDefault();
        Auth.clearFormErrors('device-reset-form');
        Auth.clearStatus('device-reset-status');

        var token = ($('#dr-code').value || '').replace(/\s+/g, '');
        if (
            !Auth.setFieldError(
                'dr-code',
                /^\d{6,10}$/.test(token) ? '' : 'Enter the code from the email — numbers only.'
            )
        ) {
            Auth.focusFirstInvalid('device-reset-form');
            return;
        }

        var release = Auth.setBusy($('#dr-submit'), 'Checking…');

        try {
            var res = await sb.auth.verifyOtp({
                email: deviceReset.email,
                token: token,
                type: 'email'
            });
            if (res.error) {
                Auth.setFieldError(
                    'dr-code',
                    'That code is wrong or has expired. Check the newest email, or send a new code.'
                );
                Auth.focusFirstInvalid('device-reset-form');
                return;
            }

            await completeDeviceReset(deviceReset.area, function (message, tone) {
                Auth.setStatus('device-reset-status', message, tone);
            });
        } catch (err) {
            console.error('Device reset failed:', err);
            Auth.setStatus(
                'device-reset-status',
                'Can’t reach the server. Check your Wi-Fi, then try again.',
                'error'
            );
        } finally {
            release();
        }
    }
    Auth.handleDeviceResetCode = handleDeviceResetCode;

    async function handleDeviceResetLink() {
        var entry = new URL(window.PIA_ENTRY_URL || window.location.href);
        if (entry.searchParams.get('flow') !== 'device-reset') {
            return false;
        }

        var hash = new URLSearchParams(entry.hash.replace(/^#/, ''));
        var session = null;
        try {
            session = (await sb.auth.getSession()).data.session;
        } catch (err) {}
        history.replaceState(null, '', entry.pathname);

        var linkToast = function (message, tone) {
            Auth.toast(
                tone === 'error' ? 'Couldn’t sign you in' : 'Signing you in',
                message,
                tone === 'error' ? 'danger' : 'accent'
            );
        };

        if (hash.get('error') || hash.get('error_code') || !session) {
            linkToast(
                hash.get('error_code') === 'otp_expired'
                    ? 'That link expired or was already used. Sign in again to get a new one.'
                    : 'That link didn’t work. Sign in again to get a new one.',
                'error'
            );
            return true;
        }

        linkToast('Signing out your other devices…', 'ok');
        await completeDeviceReset(null, linkToast);
        return true;
    }
    Auth.handleDeviceResetLink = handleDeviceResetLink;
})();
