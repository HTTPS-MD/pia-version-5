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


