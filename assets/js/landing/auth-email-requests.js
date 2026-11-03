/*
 * Activate account and forgot password.
 * Sends the email link and shows the wait time before sending again.
 */
(function () {
    'use strict';

    var Auth = window.PIAAuth;

    var emailRequests = {
        activate: {
            prefix: 'ac',
            title: 'Activate your account',
            pending: false,
            until: 0,
            version: 0,
            accepted: false,
            limited: false,
            waitKnown: false
        },
        forgot: {
            prefix: 'fp',
            title: 'Reset your password',
            pending: false,
            until: 0,
            version: 0,
            accepted: false,
            limited: false,
            waitKnown: false
        }
    };

    var emailTimer = null;

    function invalidateEmailView(id) {
        Object.keys(emailRequests).forEach(function (kind) {
            if (id === 'modal-' + kind) {
                emailRequests[kind].version++;
            }
        });
    }
    Auth.invalidateEmailView = invalidateEmailView;

    function renderEmailRequests() {
        clearTimeout(emailTimer);
        var ticking = false;
        Object.keys(emailRequests).forEach(function (kind) {
            var state = emailRequests[kind],
                p = state.prefix;
            var remaining = Math.max(0, Math.ceil((state.until - Date.now()) / 1000));
            var open = $('#modal-' + kind).classList.contains('is-open');
            $('#' + kind + '-form').hidden = state.accepted;
            $('#' + p + '-accepted').hidden = !state.accepted;
            $('#' + p + '-footer').hidden = state.accepted;
            $('#' + kind + '-title').textContent = state.accepted
                ? 'Check your email'
                : state.title;
            $('#' + kind + '-description').hidden = state.accepted;
            $('#' + p + '-submit').disabled = state.pending || remaining > 0;
            $('#' + p + '-submit').textContent = state.pending
                ? 'Sending…'
                : kind === 'activate'
                  ? 'Send activation link'
                  : 'Send reset email';
            $('#' + p + '-resend').disabled = state.pending || remaining > 0;
            $('#' + p + '-change-email').disabled = state.pending;
            $('#' + p + '-resend').textContent = state.pending ? 'Sending…' : 'Resend email';
            $('#' + p + '-email').disabled = state.pending;

            if (state.limited && remaining) {
                $('#' + p + '-cooldown').textContent = '';
                Auth.setStatus(
                    kind + '-status',
                    state.waitKnown
                        ? 'Too many email requests. Try again in ' +
                              remaining +
                              (remaining === 1 ? ' second.' : ' seconds.')
                        : 'Too many email requests. Please wait a few minutes, then try again.',
                    'error'
                );
            } else {
                if (state.limited) {
                    state.limited = false;
                    Auth.clearStatus(kind + '-status');
                }
                $('#' + p + '-cooldown').textContent = remaining
                    ? 'You can request another email in ' + remaining + ' seconds.'
                    : '';
            }
            if (remaining && open) {
                ticking = true;
            }
        });
        if (ticking) {
            emailTimer = setTimeout(renderEmailRequests, 1000);
        }
    }
    Auth.renderEmailRequests = renderEmailRequests;

    function retryDelay(error) {
        var raw =
            error &&
            (error.retry_after ||
                error.retryAfter ||
                (error.headers && error.headers.get && error.headers.get('Retry-After')));
        if (raw && Number.isFinite(Number(raw))) {
            return Math.max(0, Number(raw) * 1000);
        }
        if (raw && Number.isFinite(Date.parse(raw))) {
            return Math.max(0, Date.parse(raw) - Date.now());
        }
        var match = String((error && error.message) || '').match(/after\s+(\d+)\s+seconds?/i);
        return match ? Number(match[1]) * 1000 : null;
    }

    var INBOXES = {
        gmail: {
            web: 'https://mail.google.com/',
            ios: 'googlegmail://',
            android: 'com.google.android.gm'
        },
        outlook: {
            web: 'https://outlook.live.com/mail/',
            ios: 'ms-outlook://',
            android: 'com.microsoft.office.outlook'
        },
        yahoo: {
            web: 'https://mail.yahoo.com/',
            ios: 'ymail://',
            android: 'com.yahoo.mobile.client.android.mail'
        },
        icloud: { web: 'https://www.icloud.com/mail', ios: 'message://', android: '' }
    };

    function inboxFor(email) {
        var domain = String(email).split('@')[1] || '';
        if (/(^|\.)(outlook|hotmail|live|msn)\./i.test(domain)) {
            return INBOXES.outlook;
        }
        if (/(^|\.)yahoo\./i.test(domain)) {
            return INBOXES.yahoo;
        }
        if (/(^|\.)(icloud|me|mac)\./i.test(domain)) {
            return INBOXES.icloud;
        }
        return INBOXES.gmail;
    }

    // Opens the mail app when the phone has it, and the web inbox otherwise.
    function openInbox(event) {
        var link = event.currentTarget;
        var ua = navigator.userAgent || '';
        var web = link.href;
        if (/Android/i.test(ua) && link.dataset.android) {
            event.preventDefault();
            window.location.href =
                'intent://#Intent;package=' +
                link.dataset.android +
                ';S.browser_fallback_url=' +
                encodeURIComponent(web) +
                ';end';
        } else if (/iPhone|iPad|iPod/i.test(ua) && link.dataset.ios) {
            event.preventDefault();
            window.location.href = link.dataset.ios;
            setTimeout(function () {
                if (!document.hidden) {
                    window.open(web, '_blank', 'noopener');
                }
            }, 1200);
        }
    }

    function emailRequestError(error) {
        var message = String((error && error.message) || '');
        if (
            Number(error && error.status) === 429 ||
            /rate.limit|too many|after.*seconds/i.test(message)
        ) {
            return 'Too many email requests. Wait for the cooldown, then try again.';
        }
        if (navigator.onLine === false || /fetch|network|connection/i.test(message)) {
            return 'The request could not be confirmed. Check your connection and your inbox before trying again.';
        }
        return 'The email request was not accepted. Try again later or contact your admin.';
    }

    async function requestEmail(kind, resend) {
        var state = emailRequests[kind],
            p = state.prefix;
        if (state.pending || Date.now() < state.until) {
            return;
        }
        Auth.clearFormErrors(kind + '-form');
        Auth.clearStatus(kind + '-status');
        var email = resend ? state.email : Auth.normalizeEmail($('#' + p + '-email').value);
        if (
            !Auth.setFieldError(
                p + '-email',
                Auth.isEmail(email) ? '' : 'Enter a valid school email address.'
            )
        ) {
            Auth.focusFirstInvalid(kind + '-form');
            return;
        }
        var version = ++state.version;
        state.limited = false;
        state.pending = true;
        renderEmailRequests();
        try {
            var res =
                kind === 'activate'
                    ? await sb.auth.signInWithOtp({
                          email: email,
                          options: {
                              shouldCreateUser: false,
                              emailRedirectTo: Auth.activationRedirect()
                          }
                      })
                    : await sb.auth.resetPasswordForEmail(email, {
                          redirectTo: Auth.activationRedirect()
                      });
            if (res.error) {
                if (
                    Number(res.error.status) === 429 ||
                    /rate.limit|too many|after.*seconds/i.test(res.error.message || '')
                ) {
                    var wait = retryDelay(res.error);
                    state.until = Date.now() + Math.max(wait || 0, 60000);
                    state.limited = version === state.version;
                    state.waitKnown = wait !== null;
                } else if (version === state.version) {
                    Auth.setStatus(kind + '-status', emailRequestError(res.error), 'error');
                }
                return;
            }

            state.until = Date.now() + 60000;
            if (version !== state.version) {
                return;
            }
            state.email = email;
            state.accepted = true;
            $('#' + p + '-sent-to').textContent = email;
            var inbox = inboxFor(email);
            var open = $('#' + p + '-open-mail');
            open.href = inbox.web;
            open.dataset.ios = inbox.ios;
            open.dataset.android = inbox.android;
            Auth.setStatus(kind + '-status', 'Email request accepted. Check your email.', 'ok');
            renderEmailRequests();
            $('#' + p + '-change-email').focus();
        } catch (error) {
            if (version === state.version) {
                Auth.setStatus(kind + '-status', emailRequestError(error), 'error');
            }
        } finally {
            state.pending = false;
            renderEmailRequests();
        }
    }

    function initEmailRequests() {
        Object.keys(emailRequests).forEach(function (kind) {
            var state = emailRequests[kind],
                p = state.prefix;
            $('#' + kind + '-form').addEventListener('submit', function (event) {
                event.preventDefault();
                requestEmail(kind, false);
            });
            $('#' + p + '-open-mail').addEventListener('click', openInbox);
            $('#' + p + '-resend').addEventListener('click', function () {
                requestEmail(kind, true);
            });
            $('#' + p + '-change-email').addEventListener('click', function () {
                state.version++;
                state.accepted = false;
                Auth.clearStatus(kind + '-status');
                renderEmailRequests();
                $('#' + p + '-email').focus();
            });
        });
        document.addEventListener('visibilitychange', renderEmailRequests);
        renderEmailRequests();
    }
    Auth.initEmailRequests = initEmailRequests;

    var GREETING_NAME_KEY = 'pia_greeting_name';
    Auth.GREETING_NAME_KEY = GREETING_NAME_KEY;
})();
