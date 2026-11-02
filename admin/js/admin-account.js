/*
 * Admin account.
 * Change password, the devices admins are signed in on, sign out, and adding admins.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function passwordRuleProblem(pw) {
        if (pw.length < 8) {
            return 'Use at least 8 characters.';
        }
        if (pw.length > 72) {
            return 'Use 72 characters or fewer.';
        }
        if (!/[A-Za-z]/.test(pw) || !/\d/.test(pw)) {
            return 'Use at least one letter and one number.';
        }
        return '';
    }

    function passwordProblem(next, current) {
        var problem = passwordRuleProblem(next);
        if (problem) {
            return problem;
        }
        if (next === current) {
            return 'Choose a password different from your current one.';
        }
        return '';
    }

    function authFailureText(error, wrongPasswordText) {
        var msg = (error && error.message) || '';
        if ((error && error.status === 429) || /rate limit|too many|security purposes/i.test(msg)) {
            return 'Too many attempts. Wait a few minutes, then try again.';
        }
        if ((error && error.status === 400) || /invalid login credentials/i.test(msg)) {
            return wrongPasswordText;
        }
        return msg || 'The request did not complete.';
    }
    Admin.authFailureText = authFailureText;

    async function handleChangePassword(event) {
        event.preventDefault();
        Admin.clearFormErrors('change-password-form');

        var current = $('#cp-current').value;
        var next = $('#cp-new').value;
        var confirm = $('#cp-confirm').value;

        var valid = true;
        valid =
            Admin.setFieldError('cp-current', current ? '' : 'Enter your current password.') &&
            valid;
        valid = Admin.setFieldError('cp-new', passwordProblem(next, current)) && valid;
        valid =
            Admin.setFieldError(
                'cp-confirm',
                confirm === next ? '' : 'The passwords do not match.'
            ) && valid;
        if (!valid) {
            return;
        }

        var release = Admin.setBusy($('#cp-submit'), 'Updating…');
        var probe = window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY, {
            auth: {
                persistSession: false,
                autoRefreshToken: false,
                detectSessionInUrl: false,
                storageKey: 'pia-password-check'
            }
        });

        try {
            var proof;
            try {
                proof = await probe.auth.signInWithPassword({
                    email: Admin.state.adminEmail,
                    password: current
                });
            } catch (err) {
                proof = {
                    error: { message: (err && err.message) || 'The request did not complete.' }
                };
            }

            if (proof.error) {
                Admin.setFieldError(
                    'cp-current',
                    authFailureText(proof.error, 'That is not your current password.')
                );
                return;
            }

            var update = await probe.auth.updateUser({ password: next });
            if (update.error) {
                Admin.setFieldError(
                    'cp-new',
                    authFailureText(update.error, 'The password was not accepted.')
                );
                Admin.toastErr('Password not changed', update.error.message);
                return;
            }

            try {
                await probe.auth.signOut({ scope: 'local' });
            } catch (err) {}

            var others = null;
            try {
                others = await sb.auth.signOut({ scope: 'others' });
            } catch (err) {
                others = { error: err };
            }

            $('#change-password-form').reset();
            setPasswordsShown(false);
            Admin.closeModal('modal-change-password');

            if (others && others.error) {
                Admin.toastOk(
                    'Password updated',
                    'Your other devices could not be signed out.'
                );
            } else {
                Admin.toastOk(
                    'Password updated',
                    'Your other devices were signed out. This one stays signed in.'
                );
            }
        } finally {
            release();
        }
    }

    function setPasswordsShown(shown) {
        $('#cp-show').checked = shown;
        ['cp-current', 'cp-new', 'cp-confirm'].forEach(function (id) {
            $('#' + id).type = shown ? 'text' : 'password';
        });
    }
    Admin.setPasswordsShown = setPasswordsShown;

    function initChangePassword() {
        $('#change-password-form').addEventListener('submit', handleChangePassword);
        $('#cp-show').addEventListener('change', function () {
            setPasswordsShown(this.checked);
        });
        ['cp-current', 'cp-new', 'cp-confirm'].forEach(function (id) {
            $('#' + id).addEventListener('input', function () {
                Admin.setFieldError(id, '');
            });
        });
    }
    Admin.initChangePassword = initChangePassword;

    var signingOut = false;

    async function signOut() {
        if (signingOut) {
            return;
        }
        signingOut = true;

        var status = $('#signout-status');
        var item = $('#user-signout');
        if (item) {
            item.disabled = true;
        }
        if (status) {
            status.textContent = 'Signing out…';
        }

        try {
            sessionStorage.setItem('is_signing_out', 'true');
        } catch (err) {}
        if (typeof piaUserSigningOut !== 'undefined') {
            piaUserSigningOut = true;
        }

        var deviceId = null;
        try {
            deviceId = localStorage.getItem('pia_device_id');
        } catch (err) {}

        if (deviceId) {
            try {
                await sb.rpc('release_device', { p_device_id: deviceId });
            } catch (err) {
                console.error('Device release failed:', err);
            }
        }

        var result;
        try {
            result = await sb.auth.signOut({ scope: 'global' });
        } catch (err) {
            result = { error: err };
        }

        if (result && result.error) {
            signingOut = false;
            try {
                sessionStorage.removeItem('is_signing_out');
            } catch (err) {}
            if (typeof piaUserSigningOut !== 'undefined') {
                piaUserSigningOut = false;
            }
            if (item) {
                item.disabled = false;
            }
            var message =
                'Sign-out failed: ' +
                ((result.error && result.error.message) || 'the server did not answer') +
                '. You are still signed in. Try again.';
            if (status) {
                status.textContent = message;
            }
            Admin.showGlobalError(message);
            return;
        }

        try {
            var theme = localStorage.getItem('pia_theme');
            localStorage.clear();
            sessionStorage.clear();
            if (deviceId) {
                localStorage.setItem('pia_device_id', deviceId);
            }
            if (theme) {
                localStorage.setItem('pia_theme', theme);
            }
        } catch (err) {}

        window.location.replace('../../index.html');
    }
    Admin.signOut = signOut;

    Admin.loadAdmins = async function loadAdmins() {
        var res = await sb
            .from('profiles')
            .select('full_name, email, status, max_devices, active_devices')
            .eq('role', 'admin')
            .order('full_name', { ascending: true });
        if (res.error) {
            throw res.error;
        }

        Admin.state.admins = res.data || [];
        renderAdmins();
    };

    function renderAdmins() {
        $('#admin-tbody').innerHTML = Admin.state.admins
            .map(function (a) {
                var pending = (a.status || '') === 'inactive';
                var signedIn = (a.active_devices || []).length > 0;
                var isYou = a.email === Admin.state.adminEmail;
                var status = pending
                    ? '<span class="badge">Awaiting activation</span>'
                    : '<span class="presence"><span class="dot ' +
                      (signedIn ? 'dot-on' : 'dot-off') +
                      '" aria-hidden="true"></span>' +
                      (signedIn ? 'Signed in' : 'Signed out') +
                      '</span>';
                return (
                    '<tr>' +
                    '<td><div class="cell-user"><span class="avatar" aria-hidden="true">' +
                    Admin.esc(Admin.initialsOf(a.full_name, a.email)) +
                    '</span>' +
                    '<span class="cell-user-text"><span class="cell-name">' +
                    Admin.esc(a.full_name || '(no name)') +
                    (isYou ? ' <span class="muted">(you)</span>' : '') +
                    '</span>' +
                    '<span class="cell-mail">' +
                    Admin.esc(a.email) +
                    '</span></span></div></td>' +
                    '<td>' +
                    status +
                    '</td>' +
                    '</tr>'
                );
            })
            .join('');
        if (!Admin.state.admins.length) {
            $('#admin-tbody').innerHTML =
                '<tr><td colspan="2"><div class="state-block"><p class="state-title">No administrators found</p></div></td></tr>';
        }
    }

    function sendAdminLinkEmail(email) {
        return sb.auth.signInWithOtp({
            email: email,
            options: { shouldCreateUser: false, emailRedirectTo: Admin.activationRedirect() }
        });
    }

    async function handleAddAdmin(event) {
        event.preventDefault();
        Admin.clearFormErrors('add-admin-form');

        var name = $('#aa-name').value.trim();
        var email = Admin.normalizeEmail($('#aa-email').value);

        var valid = true;
        valid = Admin.setFieldError('aa-name', name ? '' : 'Full name is required.') && valid;
        valid =
            Admin.setFieldError(
                'aa-email',
                Admin.isEmail(email) ? '' : 'Enter a valid email address.'
            ) && valid;
        if (!valid) {
            return;
        }

        var existing = await sb.from('profiles').select('role').eq('email', email).maybeSingle();
        if (existing.error) {
            Admin.toastErr(
                'Could not check the email',
                Admin.friendlyDbError(existing.error, 'Unknown database error.')
            );
            return;
        }
        if (existing.data) {
            var role = String(existing.data.role || 'student')
                .trim()
                .toLowerCase();
            Admin.setFieldError(
                'aa-email',
                role === 'admin'
                    ? 'This account is already an administrator.'
                    : role === 'teacher'
                      ? 'This email belongs to a professor account. Use a different email for administrator access.'
                      : 'This email belongs to a study participant. Participants cannot be administrators.'
            );
            return;
        }

        var ok = await Admin.confirmAction({
            heading: 'Add ' + email + ' as administrator?',
            message:
                'They will see every participant and result, control the stages, and delete accounts. ' +
                'Only the project owner can remove them later. They get a one-time link to set a password.',
            confirmLabel: 'Create administrator',
            tone: 'accent'
        });
        if (!ok) {
            return;
        }

        var release = Admin.setBusy($('#aa-submit'), 'Creating…');

        try {
            var authRes = await sb.rpc('admin_create_auth_user', {
                target_email: email,
                default_password: Admin.generateSecurePassword()
            });
            if (authRes.error) {
                Admin.toastErr(
                    'Account not created',
                    Admin.friendlyDbError(authRes.error, 'Could not create the sign-in account.')
                );
                return;
            }

            var insertRes = await sb.from('profiles').insert([
                {
                    full_name: name,
                    email: email,
                    role: 'admin',
                    status: 'inactive'
                }
            ]);
            if (insertRes.error) {
                Admin.showNotice(
                    'Administrator not finished',
                    Admin.friendlyDbError(insertRes.error, 'Could not save the profile.') +
                        '\n\nA sign-in account was already created for ' +
                        email +
                        '. Delete it in Supabase (Authentication → Users) before trying again.',
                    'danger'
                );
                return;
            }

            Admin.closeModal('modal-add-admin');
            $('#add-admin-form').reset();
            Admin.clearFormErrors('add-admin-form');

            var mail = await sendAdminLinkEmail(email);
            if (mail.error) {
                Admin.showNotice(
                    'Administrator created, email not sent',
                    email +
                        ' is set up, but the link could not be sent: ' +
                        mail.error.message +
                        '\n\nThey can ask for a new link themselves with Activate account on the sign-in page.',
                    'danger'
                );
            } else {
                Admin.toastOk(
                    'Administrator added',
                    email + ' will get a link to choose their password.'
                );
            }

            await Admin.loadAdmins();
        } finally {
            release();
        }
    }
    Admin.handleAddAdmin = handleAddAdmin;
})();
