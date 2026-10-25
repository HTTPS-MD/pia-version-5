/*
 * Idle timeout.
 * Signs out after a long time with no activity, with a warning first.
 */
const IDLE_LIMIT_MS = 15 * 60 * 1000;

const IDLE_WARNING_MS = 60 * 1000;

let idleTimeoutId = null;

let idleCountdownId = null;

let idleWatchdogStarted = false;

const IDLE_ACTIVITY_KEY = 'pia_last_activity';

function startIdleWatchdog(opts) {
    if (idleWatchdogStarted) return;
    idleWatchdogStarted = true;

    const limitMs = (opts && opts.limitMs) || IDLE_LIMIT_MS;
    const onTimeout =
        opts && typeof opts.onTimeout === 'function' ? opts.onTimeout : () => executeForceLogout();
    const quietMs = limitMs - IDLE_WARNING_MS;
    let lastWrite = 0;

    const markActivity = () => {
        const now = Date.now();
        if (now - lastWrite < 5000) return;
        lastWrite = now;
        try {
            localStorage.setItem(IDLE_ACTIVITY_KEY, String(now));
        } catch (e) {}
    };
    const lastActivityAnywhere = () => {
        try {
            return Number(localStorage.getItem(IDLE_ACTIVITY_KEY)) || 0;
        } catch (e) {
            return 0;
        }
    };

    const dismissWarning = () => {
        clearInterval(idleCountdownId);
        idleCountdownId = null;
        const box = document.getElementById('pia-idle-modal');
        if (box) box.remove();
    };

    const resetIdle = () => {
        if (piaSessionEnded) return;
        markActivity();
        clearTimeout(idleTimeoutId);
        dismissWarning();
        idleTimeoutId = setTimeout(showIdleWarning, quietMs);
    };

    function showIdleWarning(fromSeconds) {
        if (document.getElementById('pia-idle-modal')) return;
        const resumed = typeof fromSeconds === 'number';

        if (!resumed) {
            const sinceActive = Date.now() - lastActivityAnywhere();
            if (sinceActive < quietMs - 1000) {
                idleTimeoutId = setTimeout(showIdleWarning, quietMs - sinceActive);
                return;
            }
        }
        let left = resumed
            ? Math.max(1, Math.round(fromSeconds))
            : Math.round(IDLE_WARNING_MS / 1000);

        const deadline = Date.now() + left * 1000;

        const modal = document.createElement('div');
        modal.id = 'pia-idle-modal';
        modal.style.cssText =
            'position:fixed;inset:0;z-index:var(--z-boot);display:flex;align-items:center;justify-content:center;padding:1rem;background:color-mix(in srgb, var(--ink) 62%, transparent);backdrop-filter:blur(5px);-webkit-backdrop-filter:blur(5px)';
        modal.innerHTML = `
            <div style="max-width:22rem;width:100%;background:var(--bg-surface);border-radius:var(--r-card);padding:var(--sp-7);text-align:center;color:var(--text);box-shadow:var(--shadow-lg)">
                <h3 style="margin:0 0 .5rem;font-size:var(--fs-h4);font-weight:800;letter-spacing:-0.01em">Are you still there?</h3>
                <p style="margin:0 0 1.25rem;font-size:var(--fs-sm);line-height:1.6;color:var(--text-muted)">You will be signed out automatically in <strong id="pia-idle-count" style="color:var(--text)">${left}</strong> seconds to keep your account safe.</p>
                <button id="pia-idle-stay" type="button" style="cursor:pointer;border:0;border-radius:var(--r-pill);padding:.85rem 1.5rem;font-size:var(--fs-body);font-weight:700;background:var(--accent);color:var(--on-accent);width:100%">I’m still here</button>
            </div>
        `;
        document.body.appendChild(modal);
        document.getElementById('pia-idle-stay').addEventListener('click', resetIdle);

        idleCountdownId = setInterval(() => {
            left = Math.ceil((deadline - Date.now()) / 1000);
            const el = document.getElementById('pia-idle-count');
            if (el) el.textContent = left;
            if (left <= 0) {
                clearInterval(idleCountdownId);
                idleCountdownId = null;
                onTimeout();
            }
        }, 1000);
    }

    ['pointerdown', 'keydown', 'scroll', 'touchstart'].forEach((evt) =>
        window.addEventListener(evt, resetIdle, { passive: true })
    );

    document.addEventListener('visibilitychange', () => {
        if (document.hidden || piaSessionEnded) return;
        const last = lastActivityAnywhere();
        if (last) {
            const since = Date.now() - last;
            if (since >= limitMs) {
                onTimeout();
                return;
            }
            if (since >= quietMs) {
                showIdleWarning((limitMs - since) / 1000);
                return;
            }
        }
        resetIdle();
    });
    // Activity in another tab dismisses this tab's warning and restarts its quiet time.
    window.addEventListener('storage', (event) => {
        if (event.key === IDLE_ACTIVITY_KEY && event.newValue) resetIdle();
    });

    resetIdle();
}
