/*
 * Student page guard.
 * Checks the session, which stage is open, and sends the student to the right page.
 */
async function resolveStudentRedirect(profile) {
    if (canEnterStage(profile, 'ocean')) {
        return (await isStageOpen('stage_ocean'))
            ? '/student/html/ocean-test.html'
            : '/student/html/waiting-room.html';
    }
    if (canEnterStage(profile, 'char')) {
        return (await isStageOpen('stage_char'))
            ? '/student/html/character-selection.html'
            : '/student/html/waiting-room.html';
    }

    if (isControlGroup(profile)) return '/student/html/assessment-complete.html';
    return (await isStageOpen('stage_dash'))
        ? '/student/html/student-dashboard.html'
        : '/student/html/waiting-room.html';
}

async function isStageOpen(stageKey) {
    if (!window.supabaseClient) return false;
    const { data } = await supabaseClient
        .from('settings')
        .select('value')
        .eq('key', stageKey)
        .maybeSingle();
    return data ? data.value === true || data.value === 'true' : false;
}

const STUDENT_STAGES = {
    ocean: { flag: 'stage_ocean', currentStage: 'OCEAN', url: '/student/html/ocean-test.html' },
    char: {
        flag: 'stage_char',
        currentStage: 'Character Selection',
        url: '/student/html/character-selection.html'
    },
    dash: {
        flag: 'stage_dash',
        currentStage: 'Tutoring Dashboard',
        url: '/student/html/student-dashboard.html'
    }
};

function isNonAssignedGroup(profile) {
    const g = profile.group_type ? profile.group_type.trim().toLowerCase() : '';
    return g === 'non-assigned' || g === 'non_assigned';
}

function isControlGroup(profile) {
    const g = profile.group_type ? profile.group_type.trim().toLowerCase() : '';
    return g === 'control';
}

function canEnterStage(profile, pageKey) {
    if (!profile) return false;
    const needsCharacter = isNonAssignedGroup(profile) && !profile.selected_character;

    if (pageKey === 'ocean') return !profile.is_ocean_done;
    if (pageKey === 'char') return !!profile.is_ocean_done && needsCharacter;
    if (pageKey === 'dash')
        return !!profile.is_ocean_done && !needsCharacter && !isControlGroup(profile);
    return false;
}

async function requireStudentSession() {
    if (!window.supabaseClient) {
        window.location.replace('/index.html');
        return null;
    }

    const {
        data: { session },
        error
    } = await supabaseClient.auth.getSession();
    if (error || !session || !session.user) {
        localStorage.removeItem('pia_user_email');
        localStorage.removeItem('pia_user_role');
        window.location.replace('/index.html');
        return null;
    }

    const email = session.user.email;

    const PROFILE_COLUMNS =
        'email, full_name, role, group_type, is_ocean_done, selected_character, current_stage';

    const { data: profile } = await supabaseClient
        .from('profiles')
        .select(PROFILE_COLUMNS)
        .eq('email', email)
        .maybeSingle();

    if (!profile) {
        // ang global sa ibaba ay kayang i-sign out pati ang bagong device.
        const why = await fetchSessionStatus();
        if (why === 'replaced' || why === 'revoked') {
            endStudentSession(why);
            return null;
        }

        const keptDeviceId = localStorage.getItem('pia_device_id');
        await supabaseClient.auth.signOut({ scope: 'global' });
        localStorage.clear();
        if (keptDeviceId) localStorage.setItem('pia_device_id', keptDeviceId);
        window.location.replace('/index.html');
        return null;
    }

    const role = profile.role ? profile.role.trim().toLowerCase() : 'student';
    if (role === 'admin') {
        window.location.replace('/admin/html/admin-dashboard.html');
        return null;
    }
    if (role === 'teacher') {
        window.location.replace('/teacher/html/teacher-dashboard.html');
        return null;
    }

    localStorage.setItem('pia_user_email', email);
    localStorage.setItem('pia_user_role', role);

    renderSignOutControl(profile);
    startIdleWatchdog();
    startPresenceHeartbeat();
    startSessionGuard();

    return profile;
}

async function enforceStudentStage(pageKey) {
    const profile = await requireStudentSession();
    if (!profile) return null;

    const cfg = STUDENT_STAGES[pageKey];

    if (!canEnterStage(profile, pageKey)) {
        window.location.replace(await resolveStudentRedirect(profile));
        return null;
    }

    //     ang tanging nag-o-override sa global flag. Ligtas ito dahil ang mga

    const hasTargetedGrant = profile.current_stage === cfg.currentStage;
    if (!hasTargetedGrant && !(await isStageOpen(cfg.flag))) {
        window.location.replace('/student/html/waiting-room.html');
        return null;
    }

    document.body.classList.remove('opacity-0');
    return profile;
}

function renderSignOutControl(profile) {
    if (document.getElementById('pia-signout-control')) return;

    const name = (profile && profile.full_name) || (profile && profile.email) || 'Student';

    const style = document.createElement('style');
    style.textContent = `
        #pia-signout-control { display:flex; align-items:center; gap:.6rem; }
        #pia-signout-control.pia-signout-floating {
            position:fixed; top:.75rem; right:.75rem; z-index:9998;
            background:var(--bg-surface); border-radius:var(--r-pill);
            padding:.35rem .5rem .35rem 1rem; box-shadow:var(--shadow-md);
        }
        #pia-signout-who { color:var(--text); font-size:var(--fs-xs); line-height:1.2;
            white-space:nowrap; max-width:42vw; overflow:hidden; text-overflow:ellipsis; }
        #pia-signout-who.pia-signout-inline { max-width:26vw; text-align:right; }
        #pia-signout-who small { display:block; color:var(--text-faint); font-size:var(--fs-xs); }
        @media (max-width: 720px) {
            .learn-bar-right > .who { display:none; }
        }
    `;
    document.head.appendChild(style);

    const own = document.querySelector('[data-signout], #signout-btn');
    if (own) {
        if (
            !document.getElementById('who-name') &&
            !document.getElementById('pia-signout-who') &&
            !own.hasAttribute('data-no-who')
        ) {
            const who = document.createElement('span');
            who.id = 'pia-signout-who';
            who.className = 'pia-signout-inline';
            who.innerHTML = `<small>Signed in as:</small>${escapeHTML(name)}`;
            own.parentNode.insertBefore(who, own);
        }

        return;
    }

    const wrap = document.createElement('div');
    wrap.id = 'pia-signout-control';
    wrap.innerHTML = `
        <span id="pia-signout-who"><small>Signed in as:</small>${escapeHTML(name)}</span>
        <button id="pia-signout-btn" class="btn btn-signout" type="button">Sign out</button>
    `;

    const slot = document.getElementById('pia-signout-slot');
    if (slot) slot.appendChild(wrap);
    else {
        wrap.classList.add('pia-signout-floating');
        document.body.appendChild(wrap);
    }

    document.getElementById('pia-signout-btn').addEventListener('click', async (e) => {
        e.currentTarget.disabled = true;
        e.currentTarget.textContent = 'Signing out…';
        await executeForceLogout();
    });
}
