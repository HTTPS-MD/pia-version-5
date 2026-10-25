/* Evaluates the student's progress state and routes them accordingly without overriding targeted access. */
async function checkUserAndStage() {
    const profile = await requireStudentSession();
    if (!profile) return;

    document.body.classList.remove('opacity-0');

    const targeted = {
        OCEAN: 'ocean',
        'Character Selection': 'char',
        'Tutoring Dashboard': 'dash'
    }[profile.current_stage];

    if (targeted && canEnterStage(profile, targeted)) {
        return window.location.replace(STUDENT_STAGES[targeted].url);
    }

    if (profile.current_stage !== 'Waiting Room') {
        await supabaseClient.rpc('set_student_stage', { p_stage: 'Waiting Room' });
    }

    if (canEnterStage(profile, 'ocean')) {
        checkAndListen('stage_ocean', 'ocean-test.html');
    } else if (canEnterStage(profile, 'char')) {
        checkAndListen('stage_char', 'character-selection.html');
    } else if (isControlGroup(profile)) {
        window.location.replace('assessment-complete.html');
    } else {
        checkAndListen('stage_dash', 'student-dashboard.html');
    }
}

async function checkAndListen(stageKey, redirectUrl) {
    if (await isStageOpen(stageKey)) {
        window.location.replace(redirectUrl);
        return;
    }

    registerChannel('waiting-room-' + stageKey, (ch) =>
        ch
            .on(
                'postgres_changes',
                {
                    event: 'UPDATE',
                    schema: 'public',
                    table: 'settings',
                    filter: `key=eq.${stageKey}`
                },
                (payload) => {
                    const newValue = payload.new.value;
                    if (newValue === true || newValue === 'true') {
                        window.location.replace(redirectUrl);
                    }
                }
            )
            .subscribe()
    );
}

checkUserAndStage();
