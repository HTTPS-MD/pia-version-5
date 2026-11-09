(function () {
    'use strict';

    var Auth = window.PIAAuth;

    var MODAL = 'modal-set-password';

    function client() {
        return window.sb || window.supabaseClient;
    }

    function temporary(error) {
        return (
            !error ||
            !error.status ||
            error.status >= 500 ||
            error.status === 429 ||
            /fetch|network|connection/i.test(error.message || '')
        );
    }

    async function handleSetPasswordLink() {
        var entry = new URL(window.PIA_ENTRY_URL || window.location.href);
        if (entry.searchParams.get('flow') !== 'set-password') {
            return false;
        }

        var sb = client();
        var overlay = document.getElementById(MODAL);
        var form = document.getElementById('sp-form');
        var submit = document.getElementById('sp-submit');
        var retry = document.getElementById('sp-retry');
        var again = document.getElementById('sp-new-link');
        var continuation = document.getElementById('sp-signin');
        var title = document.getElementById('sp-title');
        var sub = document.getElementById('sp-sub');
        var hash = new URLSearchParams(entry.hash.slice(1));
        var type = hash.get('type') || entry.searchParams.get('type');
        var tokenHash = entry.searchParams.get('token_hash');
        var accessToken = hash.get('access_token');
        var errorCode = hash.get('error_code') || entry.searchParams.get('error_code');
        var linkError = errorCode || hash.get('error') || entry.searchParams.get('error');

        var linkEmail = Auth.normalizeEmail(entry.searchParams.get('email'));
        var known = Auth.isEmail(linkEmail) ? linkEmail : '';
        try {
            known = known || Auth.normalizeEmail(localStorage.getItem('pia_link_email'));
        } catch (err) {}
        if (!Auth.isEmail(known)) {
            known = '';
        }
        var verifiedUser = null;
        var verifiedSession = null;
        var verifiedExchange = null;
        var mode = null;
        var busy = false;
        var passwordSaved = false;
        var profileSaved = false;
        var uncertain = false;
        var finished = false;
        var label = 'Confirm and sign in';
        var accountRole = 'student';

        function status(text, tone) {
            Auth.setStatus('sp-status', text, tone);
        }

        function refuse(text, canRetry) {
            verifiedUser = null;
            title.textContent = /expired/i.test(text) ? 'Link expired' : 'Link problem';
            sub.hidden = true;
            form.hidden = true;
            submit.hidden = true;
            retry.hidden = !canRetry;
            offerNext();
            status(text, 'error');
        }

        function offerNext() {
            again.hidden = !known;
            continuation.hidden = !!known;
            continuation.textContent = 'Back to sign in';
        }

        function unusable(error) {
            if (error && error.code === 'otp_expired') {
                refuse('This link has expired or was already used.', false);
            } else if (temporary(error)) {
                refuse(
                    'We could not verify this link right now. Check your connection and retry.',
                    true
                );
            } else {
                refuse('This link could not be verified.', false);
            }
        }

        new MutationObserver(function () {
            if (!overlay.classList.contains('is-open') && !finished) {
                finished = true;
                try {
                    sb.auth.signOut({ scope: 'local' });
                } catch (err) {}
            }
        }).observe(overlay, { attributes: true, attributeFilter: ['class'] });

        history.replaceState(null, '', entry.pathname);
        document.documentElement.removeAttribute('data-session');
        Auth.maskPasswords(overlay);
        Auth.openModal(MODAL);
        status('Checking your link…', 'ok');
        form.hidden = true;
        submit.hidden = true;

        async function verifyLink() {
            if (busy) {
                return;
            }
            busy = true;
            retry.disabled = true;
            try {
                if (!sb) {
                    return refuse(
                        'The sign-in service is unavailable. Reload this page when your connection is restored.',
                        false
                    );
                }
                if (linkError) {
                    return refuse(
                        errorCode === 'otp_expired'
                            ? 'This link has expired or was already used.'
                            : 'The email link reported an error and could not be verified.',
                        false
                    );
                }
                if (
                    (!accessToken && !tokenHash) ||
                    !['recovery', 'invite', 'magiclink', 'signup', 'email'].includes(type)
                ) {
                    return refuse(
                        'Open this page using the activation or reset link in your email.',
                        false
                    );
                }

                if (tokenHash && !verifiedExchange) {
                    var exchanged = await sb.auth.verifyOtp({ token_hash: tokenHash, type: type });
                    if (exchanged.error) {
                        return unusable(exchanged.error);
                    }
                    verifiedExchange = exchanged.data.session;
                }
                var result = await sb.auth.getSession();
                if (result.error) {
                    return unusable(result.error);
                }
                var session = result.data.session;
                var linkToken = tokenHash
                    ? verifiedExchange && verifiedExchange.access_token
                    : accessToken;
                if (!session || !linkToken || session.access_token !== linkToken) {
                    return refuse(
                        'No verified session matches this email link. Open a new activation or reset link.',
                        false
                    );
                }
                var identity = await sb.auth.getUser(linkToken);
                if (identity.error) {
                    return unusable(identity.error);
                }
                if (!identity.data.user || identity.data.user.id !== session.user.id) {
                    return refuse('The account for this link could not be verified.', false);
                }
                verifiedUser = identity.data.user;
                verifiedSession = session.access_token;

                mode = type === 'recovery' ? 'reset' : type === 'email' ? null : 'activate';
                if (!mode) {
                    return refuse(
                        'This link does not identify an activation or password reset.',
                        false
                    );
                }
                title.textContent = 'Set your password';
                sub.textContent = 'Use at least 8 characters, including a letter and a number.';
                sub.hidden = false;
                retry.hidden = true;
                again.hidden = true;
                continuation.hidden = true;
                form.hidden = false;
                submit.hidden = false;
                submit.disabled = false;
                status('', null);
                document.getElementById('sp-password').focus();
            } catch (error) {
                refuse('We could not verify the link. Check your connection and retry.', true);
            } finally {
                busy = false;
                retry.disabled = false;
            }
        }

        async function signInStaff(email, password, role) {
            try {
                var auth = await sb.auth.signInWithPassword({ email: email, password: password });
                if (auth.error) {
                    return false;
                }
                var profile = await sb
                    .from('profiles')
                    .select('*')
                    .eq('email', email)
                    .maybeSingle();
                if (profile.error || !profile.data) {
                    await sb.auth.signOut({ scope: 'local' });
                    return false;
                }
                try {
                    localStorage.setItem('pia_user_email', email);
                    localStorage.setItem('pia_user_role', role);
                } catch (err) {}

                var seat = { allowed: true };
                if (typeof claimStudentSession === 'function') {
                    seat = await claimStudentSession();
                }
                if (seat.missing && typeof enforceDeviceLimit === 'function') {
                    seat = await enforceDeviceLimit(email, profile.data);
                }
                if (!seat.allowed) {
                    await sb.auth.signOut({ scope: 'local' });
                    try {
                        localStorage.removeItem('pia_user_email');
                        localStorage.removeItem('pia_user_role');
                    } catch (err) {}
                    return false;
                }
                form.hidden = true;
                try {
                    localStorage.removeItem('pia_link_email');
                } catch (err) {}
                window.location.replace(
                    role === 'admin'
                        ? 'admin/html/admin-dashboard.html'
                        : 'teacher/html/teacher-dashboard.html'
                );
                return true;
            } catch (err) {
                try {
                    await sb.auth.signOut({ scope: 'local' });
                } catch (inner) {}
                return false;
            }
        }

        retry.addEventListener('click', verifyLink);

        again.addEventListener('click', async function () {
            if (!known || again.disabled) {
                return;
            }
            again.disabled = true;
            again.textContent = 'Requesting…';
            Auth.setEmailIntro(
                'Request a new link',
                'Enter your school email. We’ll send you a new link.'
            );
            try {
                await Auth.sendLinkTo(known);
            } catch (err) {}
            finished = true;
            Auth.closeModal(MODAL, true);
            Auth.openAuth('forgot');
        });

        continuation.addEventListener('click', function () {
            finished = true;
            Auth.closeModal(MODAL, true);
            Auth.openAuth(['admin', 'teacher'].includes(accountRole) ? 'staff' : 'signin');
        });

        form.addEventListener('submit', async function (event) {
            event.preventDefault();
            if (busy || uncertain || !verifiedUser || submit.disabled) {
                return;
            }
            var password = document.getElementById('sp-password').value;
            var confirm = document.getElementById('sp-confirm').value;
            Auth.clearFormErrors('sp-form');
            if (!passwordSaved) {
                if (password.length < 8 || !/[A-Za-z]/.test(password) || !/\d/.test(password)) {
                    Auth.setFieldError(
                        'sp-password',
                        'Use at least 8 characters, including a letter and a number.'
                    );
                    document.getElementById('sp-password').focus();
                    return;
                }
                if (password !== confirm) {
                    Auth.setFieldError('sp-confirm', 'Passwords do not match.');
                    document.getElementById('sp-confirm').focus();
                    return;
                }
            }
            busy = true;
            submit.disabled = true;
            submit.textContent = passwordSaved ? 'Finishing…' : 'Saving…';
            var operation = 'identity';
            try {
                if (!passwordSaved || !profileSaved) {
                    var current = await sb.auth.getSession();
                    if (current.error) {
                        throw current.error;
                    }
                    if (
                        !current.data.session ||
                        current.data.session.access_token !== verifiedSession
                    ) {
                        return refuse(
                            'Your session changed. Reopen your email link before setting a password.',
                            false
                        );
                    }
                    var checked = await sb.auth.getUser();
                    if (checked.error) {
                        throw checked.error;
                    }
                    if (!checked.data.user || checked.data.user.id !== verifiedUser.id) {
                        return refuse('Your account could not be verified.', false);
                    }
                }
                if (!passwordSaved) {
                    operation = 'password';
                    var updated = await sb.auth.updateUser({ password: password });
                    if (updated.error) {
                        if (temporary(updated.error)) {
                            throw updated.error;
                        }
                        Auth.setFieldError(
                            'sp-password',
                            updated.error.code === 'same_password'
                                ? 'Choose a password different from your old one.'
                                : 'The password was not accepted. Check the requirements and try again.'
                        );
                        document.getElementById('sp-password').focus();
                        status('Your password was not saved.', 'error');
                        return;
                    }
                    passwordSaved = true;
                    document.getElementById('sp-password').value = '';
                    document.getElementById('sp-confirm').value = '';
                    form.querySelectorAll('input').forEach(function (input) {
                        input.disabled = true;
                    });
                }
                if (!profileSaved) {
                    operation = 'profile';
                    var profile = await sb
                        .from('profiles')
                        .update({ status: 'active' })
                        .eq('email', verifiedUser.email)
                        .select('email, role')
                        .maybeSingle();
                    if (profile.error) {
                        throw profile.error;
                    }
                    if (!profile.data) {
                        throw new Error('Profile confirmation unavailable');
                    }
                    accountRole = profile.data.role || 'student';
                    profileSaved = true;
                }
                operation = 'signout';
                var email = verifiedUser.email;
                var signedOut = await sb.auth.signOut();
                if (signedOut.error) {
                    throw signedOut.error;
                }
                finished = true;
                if (password && ['admin', 'teacher'].includes(accountRole)) {
                    status('Password saved. Signing you in…', 'ok');
                    if (await signInStaff(email, password, accountRole)) {
                        return;
                    }
                }
                form.hidden = true;
                submit.hidden = true;
                continuation.hidden = false;
                continuation.textContent = 'Sign in';
                try {
                    localStorage.removeItem('pia_link_email');
                } catch (err) {}
                title.textContent = mode === 'reset' ? 'Password updated' : 'Account activated';
                sub.hidden = true;
                status(
                    mode === 'reset'
                        ? 'Your password has been updated. Sign in with your new password.'
                        : 'Your account is activated. Sign in with your new password.',
                    'ok'
                );
                verifiedUser = null;
            } catch (error) {
                if (operation === 'password') {
                    uncertain = true;
                    status(
                        'The save result could not be confirmed. Do not submit again. Check your connection, then request a fresh reset email if needed.',
                        'error'
                    );
                    offerNext();
                } else {
                    status(
                        passwordSaved
                            ? 'Your password was saved, but setup could not finish. Check your connection, then choose Finish setup. This will not resubmit your password.'
                            : 'Your account could not be checked. Check your connection and try again.',
                        'error'
                    );
                }
            } finally {
                busy = false;
                submit.disabled = uncertain || !verifiedUser;
                submit.textContent = passwordSaved ? 'Finish setup' : label;
            }
        });

        verifyLink();
        return true;
    }
    Auth.handleSetPasswordLink = handleSetPasswordLink;
})();
