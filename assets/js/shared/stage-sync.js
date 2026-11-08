/*
 * Stage sync.
 * Moves the student to the right page when the admin opens or closes a stage.
 */
function isOnPage(page) {
    const bare = (value) => String(value).replace(/\.html$/, '');
    return bare(window.location.pathname).endsWith('/' + bare(page));
}

const STAGE_PAGES = {
    OCEAN: { url: 'ocean-test.html', pages: ['ocean-test.html'] },
    'Character Selection': { url: 'character-selection.html', pages: ['character-selection.html'] },
    'Tutoring Dashboard': { url: 'student-dashboard.html', pages: ['student-dashboard.html'] },
    'Waiting Room': { url: 'waiting-room.html', pages: ['waiting-room.html', 'thank-you.html'] }
};

function setupStudentRealtimeStageSync() {
    const userEmail = localStorage.getItem('pia_user_email');
    const userRole = localStorage.getItem('pia_user_role');

    if (!userEmail || !window.supabaseClient || userRole === 'admin') return;

    let lastSeenStage = null;

    registerChannel('student-stage-sync-' + userEmail.replace(/[@.]/g, '_'), (ch) =>
        ch
            .on(
                'postgres_changes',
                {
                    event: 'UPDATE',
                    schema: 'public',
                    table: 'profiles',
                    filter: `email=eq.${userEmail}`
                },
                (payload) => {
                    const updatedProfile = payload.new;
                    if (
                        !updatedProfile ||
                        !updatedProfile.current_stage ||
                        updatedProfile.role === 'admin'
                    )
                        return;

                    const stage = updatedProfile.current_stage;
                    if (stage === lastSeenStage) return;
                    lastSeenStage = stage;

                    const target = STAGE_PAGES[stage];
                    if (!target) return;

                    // a closed stage sends the student to the Waiting Room at once, even in the middle of a question
                    if (target.pages.some(isOnPage)) return;

                    window.location.replace(target.url);
                }
            )
            .subscribe()
    );
}

document.addEventListener('DOMContentLoaded', () => {
    validateDeviceOnLoad();
    watchDeviceSession();
    setupStudentRealtimeStageSync();

    document.querySelectorAll('[data-signout]').forEach((btn) => {
        btn.addEventListener('click', () => {
            if (typeof executeForceLogout === 'function') executeForceLogout();
        });
    });
});
