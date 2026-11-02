/*
 * Dialogs and small helpers.
 * Opening and closing windows, confirm boxes, toasts and busy buttons.
 */
(function () {
    'use strict';

    var Dash = window.PIADash;

    var openLayers = [];

    var Z_OVERLAY_BASE = 100;

    var lastFocused = null;

    var FOCUSABLE =
        'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]),' +
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

    function openModal(id) {
        var overlay = document.getElementById(id);
        if (!overlay || openLayers.indexOf(overlay) !== -1) {
            return;
        }

        if (!openLayers.length) {
            lastFocused = document.activeElement;
            lockScroll();
        }

        overlay.classList.add('is-mounted');
        openLayers.push(overlay);

        overlay.style.zIndex = String(Z_OVERLAY_BASE + openLayers.length);
        void overlay.offsetWidth;
        overlay.classList.add('is-open');

        var first = overlay.querySelector('button, input, select, textarea');
        if (first) {
            first.focus({ preventScroll: true });
        }
    }
    Dash.openModal = openModal;

    function closeModal(target) {
        var overlay = typeof target === 'string' ? document.getElementById(target) : target;
        overlay = overlay || openLayers[openLayers.length - 1];
        if (!overlay) {
            return;
        }

        overlay.classList.remove('is-open');
        overlay.style.zIndex = '';
        openLayers = openLayers.filter(function (l) {
            return l !== overlay;
        });

        setTimeout(function () {
            overlay.classList.remove('is-mounted');
            if (!openLayers.length) {
                unlockScroll();
                if (lastFocused && lastFocused.focus) {
                    lastFocused.focus({ preventScroll: true });
                }
            }
        }, 160);
    }
    Dash.closeModal = closeModal;

    document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape' && Dash.state.preview !== null && !openLayers.length) {
            Dash.closePreview();
        }
    });

    function initModals() {
        $$('.overlay').forEach(function (overlay) {
            overlay.addEventListener('mousedown', function (e) {
                if (e.target === overlay && !overlay.hasAttribute('data-static')) {
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

                if (!top.hasAttribute('data-static')) {
                    closeModal(top);
                }
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

            var first = nodes[0],
                last = nodes[nodes.length - 1];
            if (event.shiftKey && document.activeElement === first) {
                event.preventDefault();
                last.focus();
            } else if (!event.shiftKey && document.activeElement === last) {
                event.preventDefault();
                first.focus();
            }
        });
    }
    Dash.initModals = initModals;

    function confirmAction(options) {
        return new Promise(function (resolve) {
            var overlay = $('#modal-confirm');
            var accept = $('#confirm-accept');

            // the question is the title and one line explains it, like every other dialog
            $('#confirm-title').textContent = options.heading || options.title || 'Are you sure?';
            $('#confirm-subtitle').textContent = options.subtitle || '';
            $('#confirm-text').textContent = options.message || '';
            accept.textContent = options.confirmLabel || 'Continue';
            accept.className = 'btn ' + (options.tone === 'accent' ? 'btn-primary' : 'btn-danger');

            var fresh = accept.cloneNode(true);
            accept.parentNode.replaceChild(fresh, accept);

            function settle(result) {
                overlay.removeEventListener('click', onBackdrop, true);
                document.removeEventListener('keydown', onEsc, true);
                resolve(result);
            }

            fresh.addEventListener('click', function () {
                closeModal(overlay);
                settle(true);
            });
            function onBackdrop(e) {
                if (e.target === overlay) {
                    settle(false);
                }
            }
            function onEsc(e) {
                if (e.key === 'Escape') {
                    settle(false);
                }
            }

            $$('[data-modal-close]', overlay).forEach(function (b) {
                b.addEventListener(
                    'click',
                    function () {
                        settle(false);
                    },
                    { once: true }
                );
            });
            overlay.addEventListener('click', onBackdrop, true);
            document.addEventListener('keydown', onEsc, true);

            openModal('modal-confirm');
        });
    }
    Dash.confirmAction = confirmAction;

    function toast(title, description, tone) {
        var stack = $('#toast-stack');
        if (!stack) {
            return;
        }

        var node = document.createElement('div');
        node.className = 'toast toast-' + (tone === 'danger' ? 'danger' : 'accent');
        node.innerHTML =
            '<svg class="icon"><use href="#i-' +
            (tone === 'danger' ? 'alert' : 'check') +
            '"></use></svg><div class="toast-text"><p class="toast-title">' +
            Dash.esc(title) +
            '</p>' +
            (description ? '<p class="toast-desc">' + Dash.esc(description) + '</p>' : '') +
            '</div>';

        stack.appendChild(node);
        void node.offsetWidth;
        node.classList.add('is-open');

        setTimeout(function () {
            node.classList.remove('is-open');
            setTimeout(function () {
                node.remove();
            }, 200);
        }, 4000);
    }
    Dash.toast = toast;

    function setBusy(button, label) {
        if (!button) {
            return function () {};
        }
        var html = button.innerHTML;
        var width = button.getBoundingClientRect().width;

        button.style.width = Math.ceil(width) + 'px';
        button.disabled = true;
        button.textContent = label || 'Checking…';

        return function release() {
            button.innerHTML = html;
            button.disabled = false;
            button.style.width = '';
        };
    }
    Dash.setBusy = setBusy;
})();
