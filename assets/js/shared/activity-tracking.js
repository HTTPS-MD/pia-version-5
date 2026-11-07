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

// Shown once per page load, as the same modal every other popup uses.
let stageClosedShown = false;
function showStageClosedNotice() {
    if (stageClosedShown || document.getElementById('pia-stage-closed')) return;
    stageClosedShown = true;
    const dialog = piaDialog({
        id: 'pia-stage-closed',
        role: 'alertdialog',
        title: 'This stage has been closed',
        text: 'Your admin closed this stage. You can finish and submit what you have started. It will not be lost, but you will not be able to start it again.',
        actions: [{ id: 'pia-stage-closed-ok', label: 'Got it', primary: true, onClick: () => dialog.close() }]
    });
}
