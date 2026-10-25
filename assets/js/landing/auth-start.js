/*
 * Start-up.
 * Wires everything together when the page is ready.
 */
(function () {
    'use strict';

    var Auth = window.PIAAuth;

    function boot() {
        Auth.initModals();
        Auth.wireHeroJoin();

        Auth.initPasswordToggles();
        Auth.initCapsLock();
        Auth.initLiveClear();

        if (typeof sb === 'undefined' || !sb) {
            document.documentElement.removeAttribute('data-session');
            $$('.overlay form').forEach(function (form) {
                form.addEventListener('submit', function (event) {
                    event.preventDefault();
                    var row = form.closest('.overlay').querySelector('.auth-status');
                    if (row) {
                        Auth.setStatus(
                            row.id,
                            'The sign-in service is unavailable. Check your connection and reload.',
                            'error'
                        );
                    }
                });
            });
            return;
        }

        $('#signin-form').addEventListener('submit', Auth.handleStudentJoin);
        $('#join-back').addEventListener('click', Auth.backToNumber);
        $('#staff-form').addEventListener('submit', Auth.handleStaffSignIn);
        Auth.initEmailRequests();
        $('#device-reset-form').addEventListener('submit', Auth.handleDeviceResetCode);
        $('#dr-resend').addEventListener('click', Auth.sendDeviceResetCode);
        $$('[data-device-reset]').forEach(function (btn) {
            btn.addEventListener('click', Auth.openDeviceReset);
        });

        $$('a[href^="#"]').forEach(function (link) {
            link.addEventListener('click', function (event) {
                var target = document.querySelector(link.getAttribute('href'));
                if (!target) {
                    return;
                }
                event.preventDefault();
                target.scrollIntoView({
                    behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches
                        ? 'auto'
                        : 'smooth',
                    block: 'start'
                });
            });
        });

        Auth.handleDeviceResetLink().then(function (handled) {
            if (handled) {
                document.documentElement.removeAttribute('data-session');
                return;
            }
            return Auth.offerResume().then(handleEntryIntent);
        });
    }

    var ENTRY_REASONS = {
        revoked: 'This device was signed out from another device. Sign in again to continue here.',
        ended: 'Your session ended. Sign in again to continue.'
    };

    function handleEntryIntent() {
        var entry;
        try {
            entry = new URL(window.PIA_ENTRY_URL || window.location.href);
        } catch (err) {
            return;
        }

        var target = entry.searchParams.get('signin');
        var reason = entry.searchParams.get('reason');
        if (!target && !reason) {
            return;
        }

        entry.searchParams.delete('signin');
        entry.searchParams.delete('reason');
        history.replaceState(null, '', entry.pathname + (entry.search || '') + entry.hash);

        if (document.documentElement.getAttribute('data-session') === 'in') {
            return;
        }

        var key = ['staff', 'activate', 'forgot'].includes(target) ? target : 'signin';
        var statusId = key === 'staff' ? 'staff-status' : 'signin-status';
        Auth.openAuth(key);
        if (ENTRY_REASONS[reason]) {
            setTimeout(function () {
                Auth.setStatus(statusId, ENTRY_REASONS[reason], 'error');
            }, 200);
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }
})();
