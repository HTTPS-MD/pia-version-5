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

        var veil = document.createElement('div');
        veil.id = 'leave-veil';
        veil.setAttribute('role', 'dialog');
        veil.setAttribute('aria-modal', 'true');
        veil.setAttribute('aria-labelledby', 'leave-title');
        veil.style.cssText =
            'position:fixed;inset:0;z-index:var(--z-boot);display:flex;align-items:center;justify-content:center;padding:1rem;' +
            'background:color-mix(in srgb, var(--ink) 55%, transparent);backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px)';

        var box = document.createElement('div');
        box.style.cssText =
            'max-width:24rem;width:100%;background:var(--bg-surface);color:var(--text);border-radius:var(--r-card);padding:var(--sp-7);text-align:center;box-shadow:var(--shadow-lg)';

        var title = document.createElement('h3');
        title.id = 'leave-title';
        title.style.cssText =
            'margin:0 0 .5rem;font-size:var(--fs-h4);font-weight:800;letter-spacing:-0.01em';
        title.textContent = 'You left the game';

        var text = document.createElement('p');
        text.style.cssText =
            'margin:0 0 1.25rem;font-size:var(--fs-sm);line-height:1.6;color:var(--text-muted)';
        text.textContent =
            'We noticed you moved away from the game. Do you want to keep going, or quit?';

        var row = document.createElement('div');
        row.style.cssText = 'display:grid;gap:.6rem';

        var keep = document.createElement('button');
        keep.type = 'button';
        keep.textContent = 'Continue';
        keep.style.cssText =
            'cursor:pointer;border:0;border-radius:var(--r-pill);padding:.85rem 1.5rem;font-size:var(--fs-body);font-weight:700;background:var(--accent);color:var(--on-accent)';
        keep.addEventListener('click', hideLeaveVeil);

        var quit = document.createElement('button');
        quit.type = 'button';
        quit.textContent = 'Quit';
        quit.style.cssText =
            'cursor:pointer;border:1px solid var(--line-input, var(--text-muted));border-radius:var(--r-pill);padding:.85rem 1.5rem;font-size:var(--fs-body);font-weight:700;background:transparent;color:var(--text)';
        quit.addEventListener('click', function () {
            quit.disabled = true;
            quitNow();
        });

        row.appendChild(keep);
        row.appendChild(quit);
        box.appendChild(title);
        box.appendChild(text);
        box.appendChild(row);
        veil.appendChild(box);
        document.body.appendChild(veil);
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
