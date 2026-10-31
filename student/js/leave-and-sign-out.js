/*
 * Leaving.
 * Sign out, quit, and the veil shown when the student leaves the tab.
 */
(function () {
    'use strict';

    var Dash = window.PIADash;

    function setHello(prefix, name) {
        var hello = $('#start-hello');
        if (!hello) {
            return;
        }
        var mark = document.createElement('mark');
        mark.textContent = name + '!';
        hello.textContent = prefix;
        hello.appendChild(mark);
    }
    Dash.setHello = setHello;

    async function signOut() {
        var mid = !!Dash.state.sessionId;
        var ok = await Dash.confirmAction({
            title: 'Quit',
            heading: mid ? 'Quit this session?' : 'Quit for now?',
            message: mid
                ? 'Your progress is saved. When you sign back in you will pick up from the same problem.'
                : 'You will be signed out. You can come back any time with your code.',
            confirmLabel: 'Quit'
        });
        if (!ok) {
            return;
        }
        await quitNow();
    }
    Dash.signOut = signOut;

    async function quitNow() {
        if (Dash.state.inSession && Dash.state.email) {
            try {
                await sb
                    .from('profiles')
                    .update({ is_in_game: false })
                    .eq('email', Dash.state.email);
            } catch (e) {}
        }

        if (typeof executeForceLogout === 'function') {
            await executeForceLogout();
        } else {
            await sb.auth.signOut({ scope: 'global' });
            window.location.replace('../../index.html');
        }
    }

    var LEAVE_GRACE_MS = 2000;

    var leave = { armed: false, timer: null, shown: false, wasHidden: false };

    function hideLeaveVeil() {
        var veil = document.getElementById('leave-veil');
        if (veil) {
            veil.remove();
        }
        leave.shown = false;
    }

    function showLeaveVeil() {
        if (leave.shown || !Dash.state.inSession || document.getElementById('pia-idle-modal')) {
            return;
        }
        leave.shown = true;

        // the same overlay and modal as the other dialogs, so it follows the site theme
        var veil = document.createElement('div');
        veil.id = 'leave-veil';
        veil.className = 'overlay is-mounted is-open';
        veil.style.zIndex = 'var(--z-boot)';
        veil.setAttribute('role', 'dialog');
        veil.setAttribute('aria-modal', 'true');
        veil.setAttribute('aria-labelledby', 'leave-title');
        veil.innerHTML =
            '<div class="modal modal-sm">' +
            '<header class="modal-head"><div class="modal-head-text">' +
            '<h2 class="modal-title" id="leave-title">You left the game</h2>' +
            '<p class="modal-sub">We noticed you moved away from the game. Do you want to keep going, or quit?</p>' +
            '</div></header>' +
            '<footer class="modal-foot">' +
            '<button type="button" class="btn btn-secondary" id="leave-quit">Quit</button>' +
            '<button type="button" class="btn btn-primary" id="leave-keep">Continue</button>' +
            '</footer></div>';
        document.body.appendChild(veil);

        var keep = document.getElementById('leave-keep');
        var quit = document.getElementById('leave-quit');
        keep.addEventListener('click', hideLeaveVeil);
        quit.addEventListener('click', function () {
            quit.disabled = true;
            quitNow();
        });
        keep.focus();
    }

    function initLeaveGuard() {
        if (leave.armed) {
            return;
        }
        leave.armed = true;

        document.addEventListener('visibilitychange', function () {
            if (document.hidden) {
                leave.wasHidden = true;
                return;
            }
            if (leave.wasHidden) {
                leave.wasHidden = false;
                showLeaveVeil();
            }
        });
        window.addEventListener('blur', function () {
            clearTimeout(leave.timer);
            leave.timer = setTimeout(showLeaveVeil, LEAVE_GRACE_MS);
        });
        window.addEventListener('focus', function () {
            clearTimeout(leave.timer);
        });
    }
    Dash.initLeaveGuard = initLeaveGuard;
})();
