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

        piaDialog({
            id: 'leave-veil',
            zIndex: 'var(--z-boot)',
            title: 'You left the game',
            text: 'We noticed you moved away from the game. Do you want to keep going, or quit?',
            actions: [
                {
                    id: 'leave-quit',
                    label: 'Quit',
                    onClick: function (btn) {
                        btn.disabled = true;
                        quitNow();
                    }
                },
                { id: 'leave-keep', label: 'Continue', primary: true, onClick: hideLeaveVeil }
            ]
        });
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
