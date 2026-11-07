const TUTOR_IMG = '../../assets/images/tutors/';
const TUTORS = {
    'pia-open': { name: 'Ava' },
    'pia-conscientious': { name: 'Cara' },
    'pia-extravert': { name: 'Theo' },
    'pia-agreeable': { name: 'Amy' },
    'pia-calm': { name: 'Kai' },
    'pia-neutral': { name: 'Noel' }
};

// A student who already has a tutor sees the tutor while they wait; the words stay "Hang tight!".
async function showTutorIfReady(profile) {
    const tutor = TUTORS[profile.selected_character];
    if (!tutor || !profile.is_ocean_done || isControlGroup(profile)) return;

    const img = document.getElementById('wait-tutor');
    const still = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    img.src = TUTOR_IMG + profile.selected_character + '/default' + (still ? '-still' : '') + '.webp';
    img.alt = tutor.name + ', your tutor';
    img.hidden = false;
    document.querySelector('.wait-card').classList.add('has-tutor');
    try {
        await img.decode();
    } catch (e) {}
}

/* Evaluates the student's progress state and routes them accordingly without overriding targeted access. */
async function checkUserAndStage() {
    const profile = await requireStudentSession();
    if (!profile) return;

    await showTutorIfReady(profile);
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
        checkAndListen('stage_ocean', 'ocean-test.html', 'OCEAN');
    } else if (canEnterStage(profile, 'char')) {
        checkAndListen('stage_char', 'character-selection.html', 'Character Selection');
    } else if (isControlGroup(profile)) {
        window.location.replace('thank-you.html');
    } else {
        checkAndListen('stage_dash', 'student-dashboard.html', 'Tutoring Dashboard');
    }
}

const SECTION_OPEN_CHECK_MS = 5000;

// A section the admin opened lets in students who finish later: ask the server at once, then every few seconds.
async function sectionOpenForMe(stageName) {
    const { data } = await supabaseClient.rpc('set_student_stage', { p_stage: stageName });
    return !!(data && data.granted);
}

async function checkAndListen(stageKey, redirectUrl, stageName) {
    if (await isStageOpen(stageKey)) {
        window.location.replace(redirectUrl);
        return;
    }

    if (await sectionOpenForMe(stageName)) {
        window.location.replace(redirectUrl);
        return;
    }

    const timer = setInterval(async () => {
        if (await sectionOpenForMe(stageName)) {
            clearInterval(timer);
            window.location.replace(redirectUrl);
        }
    }, SECTION_OPEN_CHECK_MS);

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
