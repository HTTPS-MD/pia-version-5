/*
 * Staff sign-in.
 * Checks the email and password, handles sign-in errors and picks the right dashboard.
 */
(function () {
    'use strict';

    var Auth = window.PIAAuth;

    function activationRedirect() {
        return emailLinkTo('assets/html/sign-up.html');
    }
    Auth.activationRedirect = activationRedirect;

    function normalizeRole(raw) {
        var role = String(raw || 'student')
            .trim()
            .toLowerCase();
        return role === 'admin' || role === 'teacher' ? role : 'student';
    }
    Auth.normalizeRole = normalizeRole;

    function areaMismatch(area, role) {
        var isStaff = role === 'teacher' || role === 'admin';
        if (area === 'staff' && !isStaff) {
            return 'This is a student account. Use Student sign in instead.';
        }
        if (area === 'student' && isStaff) {
            return 'This is a staff account. Use Teacher / Admin sign in, below.';
        }
        return '';
    }
    Auth.areaMismatch = areaMismatch;

    function friendlyAuthError(error) {
        var raw = String((error && error.message) || '');
        if (/invalid login credentials/i.test(raw)) {
            return 'The email or password is incorrect. Check both and try again.';
        }
        if (/email not confirmed/i.test(raw)) {
            return 'Activate your account before signing in.';
        }
        if (/rate limit|too many/i.test(raw)) {
            return 'Too many sign-in attempts. Please wait before trying again.';
        }
        return 'Sign in could not be completed. Check your connection or try again later.';
    }
    Auth.friendlyAuthError = friendlyAuthError;

    var signInPending = false;

    async function signIn(opts) {
        if (signInPending) {
            return;
        }
        if ($('#' + opts.submitId).disabled) {
            return;
        }
        Auth.clearFormErrors(opts.formId);
        Auth.clearStatus(opts.statusId);

        var offer = $('#' + opts.formId + ' [data-device-reset]');
        if (offer) {
            offer.hidden = true;
        }

        var email = Auth.normalizeEmail($('#' + opts.emailId).value);
        var password = $('#' + opts.passwordId).value;

        var valid = true;
        valid =
            Auth.setFieldError(
                opts.emailId,
                Auth.isEmail(email) ? '' : 'Enter a valid school email address.'
            ) && valid;
        valid =
            Auth.setFieldError(opts.passwordId, password ? '' : 'Enter your password.') && valid;
        if (!valid) {
            Auth.focusFirstInvalid(opts.formId);
            return;
        }

        Auth.maskPasswords($('#' + opts.formId));

        var overlay = $('#' + opts.formId).closest('.overlay');
        var version = overlay.dataset.authVersion || '0';
        var current = function () {
            return (
                overlay.classList.contains('is-open') &&
                (overlay.dataset.authVersion || '0') === version
            );
        };
        signInPending = true;
        var release = Auth.setBusy($('#' + opts.submitId), 'Signing in…');

        try {
            var auth = await sb.auth.signInWithPassword({ email: email, password: password });

            if (!current()) {
                if (!auth.error) {
                    await sb.auth.signOut({ scope: 'local' });
                }
                return;
            }
            if (auth.error) {
                Auth.setStatus(opts.statusId, friendlyAuthError(auth.error), 'error');
                return;
            }

            var profileRes = await sb
                .from('profiles')
                .select('*')
                .eq('email', auth.data.user.email)
                .maybeSingle();

            if (!current()) {
                await sb.auth.signOut({ scope: 'local' });
                return;
            }

            if (profileRes.error || !profileRes.data) {
                await sb.auth.signOut({ scope: 'local' });
                Auth.setStatus(
                    opts.statusId,
                    'This account is not set up yet. Please contact the study administrator.',
                    'error'
                );
                return;
            }

            var profile = profileRes.data;
            var role = normalizeRole(profile.role);

            var mismatch = areaMismatch(opts.area, role);
            if (mismatch) {
                await sb.auth.signOut({ scope: 'local' });
                Auth.setStatus(opts.statusId, mismatch, 'error');
                return;
            }

            try {
                localStorage.setItem('pia_user_email', auth.data.user.email);
                localStorage.setItem('pia_user_role', role);
            } catch (err) {}

            var check = await claimSeat(auth.data.user.email, profile, role);
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
                Auth.setStatus(opts.statusId, check.reason, 'error');

                if (check.deviceLimit) {
                    Auth.deviceReset.email = email;
                    Auth.deviceReset.area = opts.area;
                    if (offer) {
                        offer.hidden = false;
                    }
                }
                return;
            }

            await routeAfterSignIn(profile, role, function (message, tone) {
                Auth.setStatus(opts.statusId, message, tone);
            });
        } catch (err) {
            if (current()) {
                Auth.setStatus(
                    opts.statusId,
                    'Can\u2019t reach the server. Check your Wi-Fi, then try again.',
                    'error'
                );
            }
        } finally {
            signInPending = false;
            release();
        }
    }

    async function claimSeat(email, profile, role) {
        // Every role is one session at a time: the newest sign-in wins and the older one ends.
        if (typeof claimStudentSession === 'function') {
            var claim = await claimStudentSession();
            if (!claim.missing) {
                return claim;
            }
        }

        if (typeof enforceDeviceLimit !== 'function') {
            return { allowed: true };
        }
        var slots = await enforceDeviceLimit(email, profile);
        return slots.allowed ? slots : { allowed: false, reason: slots.reason, deviceLimit: true };
    }
    Auth.claimSeat = claimSeat;

    function handleStaffSignIn(event) {
        event.preventDefault();
        return signIn({
            area: 'staff',
            formId: 'staff-form',
            emailId: 'st-email',
            passwordId: 'st-password',
            submitId: 'st-submit',
            statusId: 'staff-status'
        });
    }
    Auth.handleStaffSignIn = handleStaffSignIn;

    async function routeAfterSignIn(profile, role, report) {
        report('Signed in. Taking you to your dashboard…', 'ok');

        if (role === 'admin') {
            window.location.replace('admin/html/admin-dashboard.html');
        } else if (role === 'teacher') {
            window.location.replace('teacher/html/teacher-dashboard.html');
        } else if (typeof resolveStudentRedirect === 'function') {
            window.location.replace(await resolveStudentRedirect(profile));
        } else {
            window.location.replace('student/html/waiting-room.html');
        }
    }
    Auth.routeAfterSignIn = routeAfterSignIn;
})();
