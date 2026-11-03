/*
 * Teacher settings.
 * Personal details and change password.
 */
(function () {
    'use strict';


    var current = { email: '', name: '' };
    var toastTimer = null;

    function toast(message) {
        var el = $('#toast');
        el.textContent = message;
        el.hidden = false;
        clearTimeout(toastTimer);
        toastTimer = setTimeout(function () {
            el.hidden = true;
        }, 6000);
    }

    function open(id) {
        var overlay = document.getElementById(id);
        overlay.classList.add('is-mounted');
        void overlay.offsetWidth;
        overlay.classList.add('is-open');
    }
    function close(id) {
        var overlay = document.getElementById(id);
        overlay.classList.remove('is-open');
        setTimeout(function () {
            overlay.classList.remove('is-mounted');
        }, 200);
    }

    function fieldError(id, message) {
        var msg = $('[data-msg-for="' + id + '"]');
        if (msg) {
            msg.textContent = message || '';
        }
        var input = document.getElementById(id);
        if (input) {
            if (message) {
                input.setAttribute('aria-invalid', 'true');
            } else {
                input.removeAttribute('aria-invalid');
            }
        }
        return !message;
    }

    function passwordProblem(next, currentPw) {
        if (next.length < 8) {
            return 'Use at least 8 characters.';
        }
        if (next.length > 72) {
            return 'Use 72 characters or fewer.';
        }
        if (!/[A-Za-z]/.test(next) || !/\d/.test(next)) {
            return 'Use at least one letter and one number.';
        }
        if (next === currentPw) {
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

    function showPasswords(on) {
        $('#cp-show').checked = on;
        ['cp-current', 'cp-new', 'cp-confirm'].forEach(function (id) {
            document.getElementById(id).type = on ? 'text' : 'password';
        });
    }

    // Update stays off until something is typed.
    function syncUpdate() {
        $('#cp-submit').disabled = !['cp-current', 'cp-new', 'cp-confirm'].some(function (id) {
            return document.getElementById(id).value !== '';
        });
    }

    function resetPasswordForm() {
        $('#password-form').reset();
        syncUpdate();
        showPasswords(false);
        ['cp-current', 'cp-new', 'cp-confirm'].forEach(function (id) {
            fieldError(id, '');
        });
        $('#cp-status').textContent = '';
    }

    async function changePassword(event) {
        event.preventDefault();
        var cur = $('#cp-current').value;
        var next = $('#cp-new').value;
        var again = $('#cp-confirm').value;

        var ok = true;
        ok = fieldError('cp-current', cur ? '' : 'Enter your current password.') && ok;
        ok = fieldError('cp-new', passwordProblem(next, cur)) && ok;
        ok = fieldError('cp-confirm', again === next ? '' : 'The passwords do not match.') && ok;
        if (!ok) {
            return;
        }

        var submit = $('#cp-submit');
        submit.disabled = true;
        submit.textContent = 'Updating…';

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
                    email: current.email,
                    password: cur
                });
            } catch (err) {
                proof = {
                    error: { message: (err && err.message) || 'The request did not complete.' }
                };
            }
            if (proof.error) {
                fieldError(
                    'cp-current',
                    authFailureText(proof.error, 'That is not your current password.')
                );
                return;
            }

            var update = await probe.auth.updateUser({ password: next });
            if (update.error) {
                fieldError(
                    'cp-new',
                    authFailureText(update.error, 'The password was not accepted.')
                );
                return;
            }

            try {
                await probe.auth.signOut({ scope: 'local' });
            } catch (err) {}

            var others;
            try {
                others = await sb.auth.signOut({ scope: 'others' });
            } catch (err) {
                others = { error: err };
            }

            resetPasswordForm();
            close('modal-password');
            toast(
                others && others.error
                    ? 'Password updated. Your other devices could not be signed out.'
                    : 'Password updated. Your other devices were signed out. This one stays signed in.'
            );
        } finally {
            submit.textContent = 'Update password';
            syncUpdate();
        }
    }

    function show(info) {
        current.email = info.email;
        current.name = info.name;
        $('#st-name').textContent = info.name || '—';
        $('#st-email').textContent = info.email || '—';
    }

    function init() {
        $('#open-password').addEventListener('click', function () {
            resetPasswordForm();
            open('modal-password');
            $('#cp-current').focus();
        });
        $('#cp-cancel').addEventListener('click', function () {
            resetPasswordForm();
            close('modal-password');
        });
        $('#modal-password').addEventListener('click', function (event) {
            if (event.target === this) {
                resetPasswordForm();
                close('modal-password');
            }
        });
        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape' && $('#modal-password').classList.contains('is-open')) {
                resetPasswordForm();
                close('modal-password');
            }
        });
        $('#password-form').addEventListener('submit', changePassword);
        $('#cp-show').addEventListener('change', function () {
            showPasswords(this.checked);
        });
        ['cp-current', 'cp-new', 'cp-confirm'].forEach(function (id) {
            document.getElementById(id).addEventListener('input', function () {
                fieldError(id, '');
                syncUpdate();
            });
        });
    }

    window.PIATeacherSettings = { show: show };
    init();
})();
