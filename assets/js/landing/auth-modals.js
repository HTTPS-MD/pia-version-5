/*
 * Sign-in windows (modals).
 * Opening and closing the windows, keeping focus inside, and locking the page behind them.
 */
(function () {
    'use strict';

    var Auth = (window.PIAAuth = {});

    var esc = escapeHTML;
    Auth.esc = esc;

    function isEmail(value) {
        return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
    }
    Auth.isEmail = isEmail;

    function normalizeEmail(raw) {
        return (raw || '').trim().toLowerCase();
    }
    Auth.normalizeEmail = normalizeEmail;

    var openLayers = [];

    var lastFocused = null;

    var FOCUSABLE =
        'button:not([disabled]), a[href], input:not([disabled]), select:not([disabled]),' +
        ' textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

    function lockScroll() {
        var gap = window.innerWidth - document.documentElement.clientWidth;
        document.documentElement.style.setProperty('--scrollbar-w', gap + 'px');
        document.body.classList.add('is-locked');
    }

    function unlockScroll() {
        document.body.classList.remove('is-locked');
        document.documentElement.style.setProperty('--scrollbar-w', '0px');
    }

    var authReturn = null;

    var backgroundNodes = [];

    function setBackgroundInert(on) {
        if (on && !backgroundNodes.length) {
            backgroundNodes = Array.from(document.body.children).filter(function (el) {
                return (
                    !el.classList.contains('overlay') &&
                    !['SCRIPT', 'SVG'].includes(el.tagName) &&
                    !el.inert
                );
            });
            backgroundNodes.forEach(function (el) {
                el.inert = true;
            });
        } else if (!on) {
            backgroundNodes.forEach(function (el) {
                el.inert = false;
            });
            backgroundNodes = [];
        }
    }

    function openModal(id) {
        var overlay = document.getElementById(id);
        if (!overlay || openLayers.includes(overlay)) {
            return;
        }
        if (!openLayers.length) {
            if (!lastFocused) {
                lastFocused = document.activeElement;
            }
            lockScroll();
            setBackgroundInert(true);
        }
        overlay.inert = false;
        overlay.classList.add('is-mounted', 'is-open');
        openLayers.push(overlay);
        var first = overlay.querySelector('[data-autofocus]');
        if (first && first.closest('[hidden]')) {
            first = null;
        }
        if (first && first.type === 'email' && first.value) {
            first = overlay.querySelector('input[type="password"]') || first;
        }
        first = first || overlay.querySelector('button:not([disabled])');
        if (first) {
            first.focus({ preventScroll: true });
        }
    }
    Auth.openModal = openModal;
    Auth.closeModal = closeModal;

    function closeModal(target, switching) {
        var overlay = typeof target === 'string' ? document.getElementById(target) : target;
        overlay = overlay || openLayers[openLayers.length - 1];
        if (!overlay) {
            return;
        }
        Auth.invalidateEmailView(overlay.id);
        if (overlay.id === 'modal-signin') {
            Auth.resetJoin();
        }
        overlay.dataset.authVersion = String(Number(overlay.dataset.authVersion || 0) + 1);
        overlay.classList.remove('is-open', 'is-mounted');
        overlay.inert = true;
        openLayers = openLayers.filter(function (layer) {
            return layer !== overlay;
        });
        $$('input[type="password"], input[data-pw-shown]', overlay).forEach(function (input) {
            input.value = '';
        });
        Auth.maskPasswords(overlay);
        if (switching) {
            return;
        }
        if (
            authReturn &&
            ['modal-forgot', 'modal-activate', 'modal-device-reset'].includes(overlay.id)
        ) {
            var context = authReturn;
            authReturn = null;
            openModal(context.id);
            if (context.focus && context.focus.isConnected) {
                context.focus.focus();
            }
            return;
        }
        authReturn = null;
        if (!openLayers.length) {
            unlockScroll();
            setBackgroundInert(false);
            var focus = lastFocused;
            lastFocused = null;
            if (focus && focus.isConnected) {
                focus.focus({ preventScroll: true });
            }
        }
    }

    var AUTH_MODALS = {
        signin: 'modal-signin',
        student: 'modal-signin',
        staff: 'modal-staff',
        activate: 'modal-activate',
        forgot: 'modal-forgot',
        'device-reset': 'modal-device-reset'
    };

    var lastSignin = 'signin';

    function openAuth(key) {
        if (key === 'back') {
            key = lastSignin;
        }
        var id = AUTH_MODALS[key];
        if (!id) {
            return;
        }
        var current = openLayers[openLayers.length - 1];
        if (current && current.id === id) {
            return;
        }
        if (
            current &&
            ['modal-signin', 'modal-staff'].includes(current.id) &&
            ['modal-forgot', 'modal-activate', 'modal-device-reset'].includes(id)
        ) {
            authReturn = { id: current.id, focus: document.activeElement };
        } else if (!current || ['modal-signin', 'modal-staff'].includes(id)) {
            authReturn = null;
        }
        if (id === 'modal-signin') {
            lastSignin = 'signin';
        }
        if (id === 'modal-staff') {
            lastSignin = 'staff';
        }
        if (current) {
            closeModal(current, true);
        }
        carryEmail(id);
        openModal(id);
        Auth.renderEmailRequests();
    }
    Auth.openAuth = openAuth;

    var lastEmail = '';

    function carryEmail(id) {
        var overlay = document.getElementById(id);
        var field = overlay && $('input[type="email"]', overlay);
        if (field && !field.value && lastEmail) {
            field.value = lastEmail;
        }
    }

    function initModals() {
        $$('[data-auth-open]').forEach(function (trigger) {
            trigger.addEventListener('click', function () {
                openAuth(trigger.getAttribute('data-auth-open'));
            });
        });

        $$('.overlay input[type="email"]').forEach(function (field) {
            field.addEventListener('input', function () {
                lastEmail = normalizeEmail(field.value);
            });
        });

        $$('.overlay').forEach(function (overlay) {
            overlay.addEventListener('mousedown', function (event) {
                if (event.target === overlay) {
                    closeModal(overlay);
                }
            });
            $$('[data-modal-close]', overlay).forEach(function (btn) {
                btn.addEventListener('click', function () {
                    closeModal(overlay);
                });
            });
        });

        document.addEventListener('keydown', function (event) {
            if (!openLayers.length) {
                return;
            }
            var top = openLayers[openLayers.length - 1];

            if (event.key === 'Escape') {
                event.preventDefault();
                closeModal(top);
                return;
            }

            if (event.key !== 'Tab') {
                return;
            }

            var nodes = $$(FOCUSABLE, top).filter(function (n) {
                return n.offsetParent !== null;
            });
            if (!nodes.length) {
                return;
            }

            var first = nodes[0];
            var last = nodes[nodes.length - 1];

            if (event.shiftKey && document.activeElement === first) {
                event.preventDefault();
                last.focus();
            } else if (!event.shiftKey && document.activeElement === last) {
                event.preventDefault();
                first.focus();
            }
        });
    }
    Auth.initModals = initModals;
})();
