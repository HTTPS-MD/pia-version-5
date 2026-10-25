/*
 * Teacher settings.
 * Personal details, change password, and the devices the teacher is signed in on.
 */
(function () {
    'use strict';

    var esc = escapeHTML;

    var current = { email: '', name: '' };
    var toastTimer = null;
    var armed = null;

    function toast(message) {
        var el = $('#toast');
        el.textContent = message;
        el.hidden = false;
        clearTimeout(toastTimer);
        toastTimer = setTimeout(function () {
            el.hidden = true;
        }, 6000);
    }

    function describeDevice(deviceId) {
        var id = String(deviceId || '');
        if (id.indexOf('Android') !== -1) {
            return { label: 'Android smartphone', glyph: 'phone' };
        }
        if (id.indexOf('iPad') !== -1) {
            return { label: 'iPad tablet', glyph: 'tablet' };
        }
        if (id.indexOf('iOS') !== -1) {
            return { label: 'iOS device', glyph: 'phone' };
        }
        if (id.indexOf('macOS') !== -1) {
            return { label: 'macOS computer', glyph: 'laptop' };
        }
        if (id.indexOf('Windows') !== -1) {
            return { label: 'Windows PC', glyph: 'monitor' };
        }
        return { label: 'Unknown device', glyph: 'monitor' };
    }

    function glyph(name) {
        return (
            '<svg class="icon icon-sm" aria-hidden="true"><use href="#i-' + name + '"></use></svg>'
        );
    }

    function renderDevices(devices) {
        var box = $('#device-list');
        var here = null;
        try {
            here = localStorage.getItem('pia_device_id');
        } catch (e) {}

        if (!devices.length) {
            box.innerHTML =
                '<p class="t-device-note">No other browsers are signed in to this account.</p>';
            return;
        }
        box.innerHTML = devices
            .map(function (id) {
                var info = describeDevice(id);
                return (
                    '<div class="device-row" data-device="' +
                    esc(id) +
                    '">' +
                    '<span class="device-glyph">' +
                    glyph(info.glyph) +
                    '</span>' +
                    '<div class="device-text"><p class="device-name">' +
                    esc(info.label) +
                    '</p></div>' +
                    (id === here
                        ? '<span class="badge badge-accent">This device</span>'
                        : '<button type="button" class="btn btn-danger-soft btn-sm" data-revoke="' +
                          esc(id) +
                          '" aria-label="Revoke ' +
                          esc(info.label) +
                          '">Revoke</button>') +
                    '</div>'
                );
            })
            .join('');
    }

    async function loadDevices() {
        var box = $('#device-list');
        box.innerHTML = '<p class="t-device-note">Loading…</p>';
        try {
            var res = await sb
                .from('profiles')
                .select('active_devices')
                .eq('email', current.email)
                .maybeSingle();
            if (res.error || !res.data) {
                box.innerHTML =
                    '<p class="t-device-note">Could not load your sessions. Reload the page.</p>';
                return;
            }
            renderDevices(res.data.active_devices || []);
        } catch (e) {
            box.innerHTML =
                '<p class="t-device-note">Could not load your sessions. Check the connection.</p>';
        }
    }

    async function revoke(button) {
        var id = button.getAttribute('data-revoke');
        if (armed !== button) {
            if (armed) {
                armed.textContent = 'Revoke';
            }
            armed = button;
            button.textContent = 'Sure?';
            setTimeout(function () {
                if (armed === button) {
                    armed = null;
                    button.textContent = 'Revoke';
                }
            }, 4000);
            return;
        }
        armed = null;
        button.disabled = true;
        try {
            var res = await sb.rpc('teacher_revoke_device', { p_device_id: id });
            if (res.error) {
                var raw = String(res.error.message || '');
                toast(
                    /PGRST202|42883|could not find the function/i.test(raw)
                        ? 'This is not available yet. The latest database update is not applied.'
                        : raw.replace(/^PIA:\s*/, '') || 'Could not end that session.'
                );
                button.disabled = false;
                button.textContent = 'Revoke';
                return;
            }
            toast('That session was ended.');
            loadDevices();
        } catch (e) {
            toast('Could not reach the server. Try again.');
            button.disabled = false;
            button.textContent = 'Revoke';
        }
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

    function resetPasswordForm() {
        $('#password-form').reset();
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
                    ? 'Password updated. Your other devices could not be signed out; revoke them under Active sessions.'
                    : 'Password updated. Your other devices were signed out. This one stays signed in.'
            );
            loadDevices();
        } finally {
            submit.disabled = false;
            submit.textContent = 'Update';
        }
    }

    function show(info) {
        current.email = info.email;
        current.name = info.name;
        $('#st-name').textContent = info.name || '—';
        $('#st-email').textContent = info.email || '—';
        loadDevices();
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
            });
        });
        $('#device-list').addEventListener('click', function (event) {
            var btn = event.target.closest('[data-revoke]');
            if (btn) {
                revoke(btn);
            }
        });
    }

    window.PIATeacherSettings = { show: show };
    init();
})();
