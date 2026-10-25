/*
 * Activity tracking.
 * Presence heartbeat and time spent in each stage.
 */
const PRESENCE_EVERY_MS = 45 * 1000;

let presenceTimerId = null;

function beatPresence() {
    if (!window.supabaseClient || document.hidden || piaSessionEnded) return;
    window.supabaseClient.rpc('touch_presence', { p_online: true }).then(
        () => {},
        () => {}
    );
}

function startPresenceHeartbeat() {
    if (presenceTimerId !== null) return;
    beatPresence();
    presenceTimerId = setInterval(beatPresence, PRESENCE_EVERY_MS);
    document.addEventListener('visibilitychange', () => {
        if (!document.hidden) beatPresence();
    });
}

const STAGE_HEARTBEAT_MS = 30 * 1000;

let stageHeartbeatTimerId = null;

let stageHeartbeatStage = null;

function beatStage() {
    if (!window.supabaseClient || !stageHeartbeatStage || piaSessionEnded) return;
    if (document.hidden) return;
    window.supabaseClient.rpc('record_heartbeat', { p_stage: stageHeartbeatStage }).then(
        (res) => {
            if (res && res.data && (res.data.locked || res.data.reason === 'stage_completed'))
                stopStageHeartbeat();
        },
        () => {}
    );
}

function startStageHeartbeat(stage) {
    if (stageHeartbeatTimerId !== null) return;
    stageHeartbeatStage = stage;
    beatStage();
    stageHeartbeatTimerId = setInterval(beatStage, STAGE_HEARTBEAT_MS);
}

function stopStageHeartbeat() {
    clearInterval(stageHeartbeatTimerId);
    stageHeartbeatTimerId = null;
    stageHeartbeatStage = null;
}

async function finalizeStageTime(stage) {
    stopStageHeartbeat();
    if (!window.supabaseClient) return;
    try {
        await window.supabaseClient.rpc('finalize_stage_time', { p_stage: stage });
    } catch (e) {}
}

function pageHasActiveWork() {
    try {
        return typeof window.PIA_HAS_ACTIVE_WORK === 'function' && !!window.PIA_HAS_ACTIVE_WORK();
    } catch (e) {
        return false;
    }
}

function showStageClosedNotice() {
    if (document.getElementById('pia-stage-closed')) return;
    const bar = document.createElement('div');
    bar.id = 'pia-stage-closed';
    bar.setAttribute('role', 'status');
    bar.style.cssText =
        'position:fixed;left:50%;bottom:1rem;transform:translateX(-50%);z-index:9997;width:min(34rem,calc(100vw - 2rem));' +
        'background:var(--bg-surface);color:var(--text);border-radius:var(--r-card);padding:var(--sp-4) var(--sp-5);' +
        'box-shadow:var(--shadow-lg);font-size:var(--fs-sm);line-height:1.5';
    bar.innerHTML =
        '<strong style="display:block;margin-bottom:2px">This stage has been closed by your teacher.</strong>' +
        'You can finish and submit what you have started. It will not be lost, but you will not be able to start it again.';
    document.body.appendChild(bar);
}
