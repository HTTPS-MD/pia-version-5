/*
 * Form helpers.
 * Status and error messages, show/hide password, caps-lock hint, busy buttons and toasts.
 */
(function () {
    'use strict';

    var Auth = window.PIAAuth;

    function setStatus(id, message, tone) {
        var row = document.getElementById(id);
        if (!row) {
            return;
        }

        var text = $('[data-status-text]', row);
        var glyph = $('use', row);

        text.textContent = message || '';
        row.classList.toggle('is-error', tone === 'error');
        row.classList.toggle('is-ok', tone === 'ok');
        if (glyph) {
            glyph.setAttribute('href', tone === 'ok' ? '/assets/icons-landing.svg#i-check' : '/assets/icons-landing.svg#i-alert');
        }
    }
    Auth.setStatus = setStatus;

    function clearStatus(id) {
        setStatus(id, '', null);
    }
    Auth.clearStatus = clearStatus;

    function setFieldError(id, message) {
        var field = document.getElementById(id);
        var msg = $('[data-msg-for="' + id + '"]');
        if (field) {
            field.classList.toggle('is-invalid', !!message);
            if (message) {
                field.setAttribute('aria-invalid', 'true');
            } else {
                field.removeAttribute('aria-invalid');
            }
        }
        if (msg) {
            msg.classList.remove('is-hint');
            msg.textContent = message || '';
        }
        return !message;
    }
    Auth.setFieldError = setFieldError;

    function clearFormErrors(formId) {
        var form = document.getElementById(formId);
        if (!form) {
            return;
        }
        $$('.field-msg', form).forEach(function (n) {
            n.textContent = '';
            n.classList.remove('is-hint');
        });
        $$('.is-invalid', form).forEach(function (n) {
            n.classList.remove('is-invalid');
            n.removeAttribute('aria-invalid');
        });
    }
    Auth.clearFormErrors = clearFormErrors;

    function initLiveClear() {
        $$('.overlay form').forEach(function (form) {
            form.addEventListener('input', function (event) {
                var field = event.target;
                if (field && field.id && field.classList.contains('is-invalid')) {
                    setFieldError(field.id, '');
                }
            });
        });
    }
    Auth.initLiveClear = initLiveClear;

    function focusFirstInvalid(formId) {
        var bad = $('#' + formId + ' .is-invalid');
        if (bad) {
            bad.focus();
        }
    }
    Auth.focusFirstInvalid = focusFirstInvalid;

    var PW_CONTROLS = '[data-pw-toggle], [data-pw-check]';

    function pwInput(control) {
        return document.getElementById(
            control.getAttribute('data-pw-toggle') || control.getAttribute('data-pw-check')
        );
    }

    function setPasswordShown(input, control, shown) {
        input.type = shown ? 'text' : 'password';
        if (shown) {
            input.setAttribute('data-pw-shown', '');
        } else {
            input.removeAttribute('data-pw-shown');
        }
        if (control.type === 'checkbox') {
            control.checked = shown;
        } else {
            control.setAttribute('aria-pressed', String(shown));
        }
    }

    function maskPasswords(root) {
        $$(PW_CONTROLS, root).forEach(function (control) {
            var input = pwInput(control);
            if (input) {
                setPasswordShown(input, control, false);
            }
        });
    }
    Auth.maskPasswords = maskPasswords;

    function initPasswordToggles() {
        $$(PW_CONTROLS).forEach(function (control) {
            var input = pwInput(control);
            if (!input) {
                return;
            }
            if (control.type === 'checkbox') {
                control.addEventListener('change', function () {
                    setPasswordShown(input, control, control.checked);
                });
            } else {
                control.addEventListener('click', function () {
                    setPasswordShown(input, control, input.type === 'password');
                });
            }
        });
    }
    Auth.initPasswordToggles = initPasswordToggles;

    function setCapsHint(input, on) {
        var msg = $('[data-msg-for="' + input.id + '"]');
        if (!msg || input.classList.contains('is-invalid')) {
            return;
        }
        if (!on && !msg.classList.contains('is-hint')) {
            return;
        }
        msg.classList.toggle('is-hint', on);
        msg.textContent = on ? 'Caps Lock is on.' : '';
    }

    function initCapsLock() {
        $$(PW_CONTROLS).forEach(function (control) {
            var input = pwInput(control);
            if (!input) {
                return;
            }
            var check = function (event) {
                if (event.getModifierState) {
                    setCapsHint(input, event.getModifierState('CapsLock'));
                }
            };
            input.addEventListener('keydown', check);
            input.addEventListener('keyup', check);
            input.addEventListener('blur', function () {
                setCapsHint(input, false);
            });
        });
    }
    Auth.initCapsLock = initCapsLock;

    function setBusy(button, busyLabel) {
        if (!button) {
            return function () {};
        }
        var html = button.innerHTML;
        var width = button.getBoundingClientRect().width;

        button.style.width = Math.ceil(width) + 'px';
        button.disabled = true;
        button.innerHTML = Auth.esc(busyLabel || 'Working…');

        return function release() {
            button.innerHTML = html;
            button.disabled = false;
            button.style.width = '';
        };
    }
    Auth.setBusy = setBusy;

    function toast(title, description, tone) {
        var stack = $('#toast-stack');
        if (!stack) {
            return;
        }

        var node = document.createElement('div');
        node.className = 'toast toast-' + (tone === 'danger' ? 'danger' : 'accent');
        node.innerHTML =
            '<svg class="icon"><use href="/assets/icons-landing.svg#i-' +
            (tone === 'danger' ? 'alert' : 'check') +
            '"></use></svg>' +
            '<div class="toast-text"><p class="toast-title">' +
            Auth.esc(title) +
            '</p>' +
            (description ? '<p class="toast-desc">' + Auth.esc(description) + '</p>' : '') +
            '</div>';

        stack.appendChild(node);
        void node.offsetWidth;
        node.classList.add('is-open');

        setTimeout(function () {
            node.classList.remove('is-open');
            setTimeout(function () {
                node.remove();
            }, 200);
        }, 4200);
    }
    Auth.toast = toast;
})();
