/*
 * Dialogs and small helpers.
 * Opening and closing windows, toasts, confirm boxes, info tips, busy buttons and field errors.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function lockScroll() {
        var gap = window.innerWidth - document.documentElement.clientWidth;
        document.documentElement.style.setProperty('--scrollbar-w', gap + 'px');
        document.body.classList.add('is-locked');
    }

    function unlockScroll() {
        document.body.classList.remove('is-locked');
        document.documentElement.style.setProperty('--scrollbar-w', '0px');
    }

    function openModal(id, trigger) {
        var overlay = document.getElementById(id);
        if (!overlay || Admin.openLayers.indexOf(overlay) !== -1) {
            return;
        }

        overlay._returnFocus = trigger || document.activeElement;
        if (!Admin.openLayers.length) {
            Admin.lastFocused = overlay._returnFocus;
            lockScroll();
        }

        overlay.classList.add('is-mounted');
        Admin.openLayers.push(overlay);

        overlay.style.zIndex = String(Admin.Z_OVERLAY_BASE + Admin.openLayers.length);

        void overlay.offsetWidth;
        overlay.classList.add('is-open');

        var first = overlay.querySelector(
            'input:not([type="hidden"]), select, textarea, button:not(.info-tip)'
        );
        if (first) {
            first.focus({ preventScroll: true });
        }
    }
    Admin.openModal = openModal;

    function closeModal(target) {
        var overlay = typeof target === 'string' ? document.getElementById(target) : target;
        overlay = overlay || Admin.openLayers[Admin.openLayers.length - 1];
        if (!overlay) {
            return;
        }

        overlay.classList.remove('is-open');
        overlay.style.zIndex = '';
        Admin.openLayers = Admin.openLayers.filter(function (layer) {
            return layer !== overlay;
        });

        $$('[data-clear-on-close]', overlay).forEach(function (field) {
            field.value = '';
        });

        if (overlay.id === 'modal-change-password') {
            Admin.setPasswordsShown(false);
            clearFormErrors('change-password-form');
        }

        setTimeout(function () {
            overlay.classList.remove('is-mounted');
            if (Admin.openLayers.length) {
                var back = overlay._returnFocus;
                if (
                    back &&
                    back.focus &&
                    document.body.contains(back) &&
                    back.offsetParent !== null
                ) {
                    back.focus({ preventScroll: true });
                }
            }
            if (!Admin.openLayers.length) {
                unlockScroll();
                if (Admin.lastFocused && Admin.lastFocused.focus) {
                    Admin.lastFocused.focus({ preventScroll: true });
                }

                Admin.flushDeferredRefresh();
            }
        }, 160);
    }
    Admin.closeModal = closeModal;

    function initModals() {
        $$('[data-modal-open]').forEach(function (trigger) {
            trigger.addEventListener('click', function () {
                openModal(trigger.getAttribute('data-modal-open'));
            });
        });

        $$('.overlay').forEach(function (overlay) {
            var noDismiss = overlay.hasAttribute('data-no-dismiss');

            if (!noDismiss) {
                overlay.addEventListener('mousedown', function (event) {
                    if (event.target === overlay) {
                        closeModal(overlay);
                    }
                });
            }

            $$('[data-modal-close]', overlay).forEach(function (btn) {
                btn.addEventListener('click', function () {
                    closeModal(overlay);
                });
            });
        });

        document.addEventListener('keydown', function (event) {
            if (!Admin.openLayers.length) {
                return;
            }
            var top = Admin.openLayers[Admin.openLayers.length - 1];

            if (event.key === 'Escape') {
                if (top.hasAttribute('data-no-dismiss')) {
                    return;
                }
                event.preventDefault();
                closeModal(top);
                return;
            }

            if (event.key !== 'Tab') {
                return;
            }

            var nodes = $$(Admin.FOCUSABLE, top).filter(function (node) {
                return node.offsetParent !== null;
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
    Admin.initModals = initModals;

    function toast(title, description, tone) {
        var stack = $('#toast-stack');
        if (!stack) {
            return;
        }

        var node = document.createElement('div');
        node.className = 'toast toast-' + (tone === 'danger' ? 'danger' : 'accent');
        node.innerHTML =
            Admin.icon(tone === 'danger' ? 'alert' : 'check') +
            '<div class="toast-text">' +
            '<p class="toast-title">' +
            Admin.esc(title) +
            '</p>' +
            (description ? '<p class="toast-desc">' + Admin.esc(description) + '</p>' : '') +
            '</div>';

        stack.appendChild(node);
        void node.offsetWidth;
        node.classList.add('is-open');

        setTimeout(
            function () {
                node.classList.remove('is-open');
                setTimeout(function () {
                    node.remove();
                }, 200);
            },
            tone === 'danger' ? 6000 : 3800
        );
    }

    function toastOk(title, description) {
        toast(title, description, 'accent');
    }
    Admin.toastOk = toastOk;

    function toastErr(title, description) {
        toast(title, description, 'danger');
    }
    Admin.toastErr = toastErr;

    function confirmAction(options) {
        return new Promise(function (resolve) {
            var overlay = $('#modal-confirm');
            var accept = $('#confirm-accept');

            $('#confirm-title').textContent = options.title || 'Confirm action';
            $('#confirm-subtitle').textContent = options.subtitle || '';
            $('#confirm-heading').textContent = options.heading || options.title || 'Are you sure?';
            $('#confirm-text').textContent = options.message || '';

            var danger = options.tone !== 'accent';
            $('#confirm-glyph').className = 'modal-hero-glyph' + (danger ? '' : ' g-accent');
            $('#confirm-glyph').innerHTML =
                '<svg class="icon icon-lg"><use href="#i-' +
                (danger ? 'alert' : 'info') +
                '"></use></svg>';

            accept.textContent = options.confirmLabel || 'Proceed';
            accept.className = 'btn ' + (danger ? 'btn-danger' : 'btn-primary');

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

            function onBackdrop(event) {
                if (event.target === overlay) {
                    settle(false);
                }
            }
            function onEsc(event) {
                if (event.key === 'Escape') {
                    settle(false);
                }
            }

            $$('[data-modal-close]', overlay).forEach(function (btn) {
                btn.addEventListener(
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
    Admin.confirmAction = confirmAction;

    function showNotice(title, body, tone) {
        $('#notice-title').textContent = 'Result';
        $('#notice-heading').textContent = title;
        $('#notice-body').textContent = body;

        var danger = tone === 'danger';
        $('#notice-glyph').className = 'modal-hero-glyph' + (danger ? '' : ' g-accent');
        $('#notice-glyph').innerHTML =
            '<svg class="icon icon-lg"><use href="#i-' +
            (danger ? 'alert' : 'info') +
            '"></use></svg>';

        openModal('modal-notice');
    }
    Admin.showNotice = showNotice;

    var tip = { bubble: null, owner: null, pinned: false, hideTimer: null };

    function tipBubble() {
        if (!tip.bubble) {
            tip.bubble = document.createElement('div');
            tip.bubble.className = 'tip-bubble';
            tip.bubble.id = 'pia-tip';
            tip.bubble.setAttribute('role', 'tooltip');
            document.body.appendChild(tip.bubble);
        }
        return tip.bubble;
    }

    function showTip(btn, pinned) {
        clearTimeout(tip.hideTimer);
        var bubble = tipBubble();
        if (tip.owner && tip.owner !== btn) {
            tip.owner.removeAttribute('aria-describedby');
        }
        tip.owner = btn;
        tip.pinned = !!pinned;
        bubble.textContent = btn.getAttribute('data-tip') || '';
        btn.setAttribute('aria-describedby', 'pia-tip');

        var margin = 8;
        var r = btn.getBoundingClientRect();
        var width = bubble.offsetWidth;
        var height = bubble.offsetHeight;
        var viewW = document.documentElement.clientWidth;
        var left = Math.max(
            margin,
            Math.min(r.left + r.width / 2 - width / 2, viewW - width - margin)
        );
        var top = r.top - height - margin;
        if (top < margin) {
            top = r.bottom + margin;
        }
        bubble.style.left = Math.round(left) + 'px';
        bubble.style.top = Math.round(top) + 'px';
        bubble.classList.add('is-shown');
    }

    function hideTip() {
        clearTimeout(tip.hideTimer);
        if (tip.owner) {
            tip.owner.removeAttribute('aria-describedby');
        }
        tip.owner = null;
        tip.pinned = false;
        if (tip.bubble) {
            tip.bubble.classList.remove('is-shown');
        }
    }

    function tipOf(target) {
        return target && target.closest ? target.closest('.info-tip') : null;
    }

    function initInfoTips() {
        document.addEventListener('mouseover', function (event) {
            var btn = tipOf(event.target);
            if (btn && !tip.pinned) {
                showTip(btn, false);
            }
        });
        document.addEventListener('mouseout', function (event) {
            var btn = tipOf(event.target);
            if (!btn || btn !== tip.owner || tip.pinned || btn.contains(event.relatedTarget)) {
                return;
            }
            tip.hideTimer = setTimeout(hideTip, 80);
        });
        document.addEventListener('focusin', function (event) {
            var btn = tipOf(event.target);
            if (btn && !tip.pinned) {
                showTip(btn, false);
            }
        });
        document.addEventListener('focusout', function (event) {
            if (event.target === tip.owner && !tip.pinned) {
                hideTip();
            }
        });
        document.addEventListener('click', function (event) {
            var btn = tipOf(event.target);
            if (btn) {
                event.preventDefault();
                if (tip.owner === btn && tip.pinned) {
                    hideTip();
                } else {
                    showTip(btn, true);
                }
                return;
            }
            if (tip.owner) {
                hideTip();
            }
        });
        window.addEventListener(
            'keydown',
            function (event) {
                if (event.key === 'Escape' && tip.owner) {
                    event.stopPropagation();
                    hideTip();
                }
            },
            true
        );
        window.addEventListener(
            'scroll',
            function () {
                if (tip.owner) {
                    hideTip();
                }
            },
            true
        );
        window.addEventListener('resize', function () {
            if (tip.owner) {
                hideTip();
            }
        });
    }
    Admin.initInfoTips = initInfoTips;

    function setBusy(button, busyLabel) {
        if (!button) {
            return function () {};
        }
        var originalHTML = button.innerHTML;
        var originalWidth = button.getBoundingClientRect().width;

        button.style.width = Math.ceil(originalWidth) + 'px';
        button.classList.add('is-busy');
        button.disabled = true;
        button.innerHTML = Admin.esc(busyLabel || 'Working…');

        return function release() {
            button.innerHTML = originalHTML;
            button.classList.remove('is-busy');
            button.disabled = false;
            button.style.width = '';
        };
    }
    Admin.setBusy = setBusy;

    function setFieldError(id, message) {
        var field = document.getElementById(id);
        var msg = $('[data-msg-for="' + id + '"]');
        if (field) {
            field.classList.toggle('is-invalid', !!message);
        }
        if (msg) {
            msg.textContent = message || '';
        }
        return !message;
    }
    Admin.setFieldError = setFieldError;

    function clearFormErrors(formId) {
        var form = document.getElementById(formId);
        if (!form) {
            return;
        }
        $$('.field-msg', form).forEach(function (node) {
            node.textContent = '';
        });
        $$('.is-invalid', form).forEach(function (node) {
            node.classList.remove('is-invalid');
        });
    }
    Admin.clearFormErrors = clearFormErrors;
})();
