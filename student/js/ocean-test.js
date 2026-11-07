const gatekeeperScreen = document.getElementById('gatekeeper-screen');
const testContainer = document.getElementById('test-container');

const STAFF = document.body.hasAttribute('data-staff');
const TEACHER_DASHBOARD = 'teacher-dashboard.html';

let isTestAllowed = false;
let currentQuestionIndex = 0;
let hasSubmitted = false;
let reviewingUnanswered = false;

let userResponses = new Array(50).fill(null);

function answeredCount() {
    return userResponses.reduce((n, v) => n + (v === null ? 0 : 1), 0);
}

function isComplete() {
    return answeredCount() === questions.length;
}

let verifiedProfile = null;

const questions = window.PIA_BFPT.items;

document.body.style.overflow = 'hidden';

const OCEAN_PROGRESS_KEY = 'pia_ocean_progress';

function saveOceanProgress() {
    if (!verifiedProfile) return;
    try {
        localStorage.setItem(
            OCEAN_PROGRESS_KEY,
            JSON.stringify({
                email: verifiedProfile.email,
                responses: userResponses,
                index: currentQuestionIndex,
                reviewingUnanswered
            })
        );
    } catch (e) {}
}

function loadOceanProgress() {
    if (!verifiedProfile) return false;
    try {
        const raw = localStorage.getItem(OCEAN_PROGRESS_KEY);
        if (!raw) return false;
        const saved = JSON.parse(raw);

        if (!saved || saved.email !== verifiedProfile.email) {
            localStorage.removeItem(OCEAN_PROGRESS_KEY);
            return false;
        }
        if (!Array.isArray(saved.responses) || saved.responses.length === 0) return false;

        const restored = new Array(questions.length).fill(null);
        saved.responses.slice(0, questions.length).forEach((v, i) => {
            if (Number.isInteger(v) && v >= 1 && v <= 5) restored[i] = v;
        });
        userResponses = restored;

        const firstGap = userResponses.indexOf(null);
        currentQuestionIndex =
            firstGap === -1 ? Math.min(saved.index || 0, questions.length - 1) : firstGap;
        reviewingUnanswered = saved.reviewingUnanswered === true && firstGap !== -1;

        return answeredCount() > 0;
    } catch (e) {
        return false;
    }
}

function clearOceanProgress() {
    try {
        localStorage.removeItem(OCEAN_PROGRESS_KEY);
    } catch (e) {}
}

function isTestInProgress() {
    return isTestAllowed && !hasSubmitted && answeredCount() > 0 && !isComplete();
}

async function requireTeacherForOcean() {
    const sb = window.supabaseClient;
    if (!sb) {
        window.location.replace('../../index.html?signin=staff');
        return null;
    }

    const {
        data: { session }
    } = await sb.auth.getSession();
    if (!session || !session.user) {
        window.location.replace('../../index.html?signin=staff');
        return null;
    }

    const { data: profile, error } = await sb
        .from('profiles')
        .select('email, full_name, role, is_ocean_done')
        .eq('email', session.user.email)
        .maybeSingle();
    if (error || !profile) {
        window.location.replace('../../index.html?signin=staff');
        return null;
    }

    const role = String(profile.role || 'student')
        .trim()
        .toLowerCase();
    if (role === 'admin') {
        window.location.replace('../../admin/html/admin-dashboard.html');
        return null;
    }
    if (role !== 'teacher') {
        window.location.replace('../../student/html/waiting-room.html');
        return null;
    }
    if (profile.is_ocean_done === true) {
        window.location.replace(TEACHER_DASHBOARD);
        return null;
    }

    document.body.classList.remove('opacity-0');
    return profile;
}

async function checkAccessAndInit() {
    verifiedProfile = STAFF ? await requireTeacherForOcean() : await enforceStudentStage('ocean');
    if (!verifiedProfile) return;

    isTestAllowed = true;

    if (STAFF) {
        window.PIA_HAS_ACTIVE_WORK = isTestInProgress;
        if (loadOceanProgress()) {
            gatekeeperScreen.classList.add('hidden');
            testContainer.classList.remove('hidden');
            document.body.style.overflow = 'auto';
            initTestUI();
            loadQuestion();
        } else {
            renderGatekeeper();
        }
        setupExitGuard();
        return;
    }

    window.PIA_HAS_ACTIVE_WORK = isTestInProgress;
    startStageHeartbeat('OCEAN');

    if (loadOceanProgress()) {
        gatekeeperScreen.classList.add('hidden');
        testContainer.classList.remove('hidden');
        document.body.style.overflow = 'auto';
        initTestUI();
        loadQuestion();
    } else {
        renderGatekeeper();
    }

    setupRealtimeListener();
    setupExitGuard();
}

function renderGatekeeper() {
    if (isTestAllowed) {
        gatekeeperScreen.innerHTML = `
            <div class="gate-wrap gate-open">
                <div id="step-container"></div>
            </div>
        `;
        showPrivacyStep();
    } else {
        gatekeeperScreen.innerHTML = `
            <div class="gate-wrap gate-open">
                <h1 class="gate-title">Not open yet</h1>
                <p class="gate-lede">
                    Your admin hasn't started the questionnaire. Head back to the waiting
                    room and it will bring you here automatically when it opens.
                </p>
                <div class="gate-actions">
                    <a href="waiting-room.html" class="btn btn-secondary btn-block">Back to the waiting room</a>
                </div>
            </div>
        `;
    }
}

function setupRealtimeListener() {
    if (supabaseClient) {
        registerChannel('realtime-ocean-stage-sync', (ch) =>
            ch
                .on(
                    'postgres_changes',
                    {
                        event: '*',
                        schema: 'public',
                        table: 'settings',
                        filter: `key=eq.stage_ocean`
                    },
                    (payload) => {
                        const isOpen = payload.new.value === true || payload.new.value === 'true';

                        if (isTestInProgress()) {
                            if (!isOpen) showStageClosedNotice();
                            return;
                        }

                        if (isOpen) {
                            window.location.reload();
                        } else {
                            window.location.href = 'waiting-room.html';
                        }
                    }
                )
                .subscribe()
        );
    }
}

const PRIVACY_TEXT = STAFF
    ? 'Only the researchers see your responses. They are never shown to your students or the school.'
    : 'Only the researchers see them. Never your classmates or teachers.';

function showPrivacyStep() {
    const container = document.getElementById('step-container');
    if (!container) return;
    container.innerHTML = `
        <h1 class="gate-title">${
            STAFF ? 'Teacher <mark>questionnaire.</mark>' : 'Hi! Let’s get to <mark>know you.</mark>'
        }</h1>
        <p class="gate-lede">${
            STAFF
                ? 'A 50-statement personality questionnaire for your teacher profile in the study. Rate how well each statement describes you.'
                : '50 quick statements. Pick how much each one sounds like you.'
        }</p>

        <ul class="gate-chips" aria-label="What to expect">
            <li>50 statements</li>
            <li>No right or wrong answers</li>
        </ul>

        <section class="privacy-note" aria-labelledby="privacy-title">
            <h2 class="privacy-title" id="privacy-title">${STAFF ? 'Your responses are confidential' : 'Your answers are private'}</h2>
            <p class="privacy-text">${PRIVACY_TEXT}</p>
        </section>

        <div class="gate-actions">
            ${STAFF ? '' : '<a href="waiting-room.html" class="btn btn-secondary">Not right now</a>'}
            <button type="button" data-action="start" class="btn btn-primary">I understand — start</button>
        </div>
    `;
}

async function startTestDirectly() {
    if (supabaseClient && !STAFF) {
        await supabaseClient.rpc('set_student_stage', { p_stage: 'OCEAN' });
    }

    gatekeeperScreen.classList.add('hidden');
    testContainer.classList.remove('hidden');
    document.body.style.overflow = 'auto';
    initTestUI();
    loadQuestion();
}

let testUIReady = false;

function initTestUI() {
    if (testUIReady) return;
    testUIReady = true;

    const list = document.getElementById('ocean-answer-list');

    document.querySelectorAll('#ocean-answer-list button[data-score]').forEach((btn) => {
        const label = window.PIA_BFPT.labelFor(Number(btn.getAttribute('data-score')));
        const slot = btn.querySelector('.answer-label');
        if (label && slot) slot.textContent = label;
    });

    if (list) {
        list.addEventListener('click', (e) => {
            const btn = e.target.closest('button[data-score]');
            if (btn) handleAnswer(Number(btn.getAttribute('data-score')));
        });
    }

    document
        .getElementById('btn-prev')
        ?.addEventListener('click', () => goToQuestion(currentQuestionIndex - 1));
    document.getElementById('btn-next')?.addEventListener('click', goToNextQuestion);
    document.getElementById('btn-submit-ocean')?.addEventListener('click', () => {
        if (isComplete()) submitTestResults();
    });

    document.addEventListener('keydown', (e) => {
        if (!isTestAllowed || hasSubmitted) return;
        if (document.getElementById('quit-modal')?.classList.contains('modal-active')) return;
        if (e.key === 'ArrowLeft') goToQuestion(currentQuestionIndex - 1);
        if (e.key === 'ArrowRight') goToNextQuestion();
        if (
            /^[1-5]$/.test(e.key) &&
            !e.ctrlKey &&
            !e.metaKey &&
            !e.altKey &&
            !e.target.closest?.('input, textarea')
        )
            handleAnswer(Number(e.key));
    });
}

function goToQuestion(index) {
    if (index < 0 || index >= questions.length) return;
    currentQuestionIndex = index;
    saveOceanProgress();
    loadQuestion();
}

function goToNextQuestion() {
    if (userResponses[currentQuestionIndex] === null) return;
    const firstGap = userResponses.indexOf(null);
    if (reviewingUnanswered) {
        if (userResponses[currentQuestionIndex] === null) return;
        if (firstGap !== -1) {
            const laterGap = userResponses.findIndex(
                (answer, index) => index > currentQuestionIndex && answer === null
            );
            goToQuestion(laterGap !== -1 ? laterGap : firstGap);
        }
        return;
    }

    if (
        currentQuestionIndex === questions.length - 1 &&
        firstGap !== -1 &&
        firstGap < currentQuestionIndex
    ) {
        reviewingUnanswered = true;
        goToQuestion(firstGap);
        return;
    }

    goToQuestion(currentQuestionIndex + 1);
}

function loadQuestion() {
    initTestUI();

    const total = questions.length;
    const i = currentQuestionIndex;

    document.getElementById('question-counter').textContent = `${i + 1} of ${total}`;
    const statement = questions[i];
    document.getElementById('question-text').textContent =
        `I… ${statement.charAt(0).toLowerCase()}${statement.slice(1)}`;

    const done = answeredCount();

    document.querySelectorAll('#ocean-answer-list .ocean-answer-btn').forEach((btn) => {
        const picked = Number(btn.getAttribute('data-score')) === userResponses[i];
        btn.classList.toggle('is-selected', picked);
        btn.setAttribute('aria-pressed', picked ? 'true' : 'false');
    });

    const prevBtn = document.getElementById('btn-prev');
    const nextBtn = document.getElementById('btn-next');
    if (prevBtn) prevBtn.disabled = i === 0;
    const isLast = i === total - 1;
    const remaining = total - done;
    const firstGap = userResponses.indexOf(null);
    const showSubmit = isComplete() && (isLast || reviewingUnanswered);
    const canReviewFromLast = isLast && firstGap !== -1 && firstGap < i;
    if (nextBtn) {
        nextBtn.hidden = showSubmit || (isLast && !canReviewFromLast && !reviewingUnanswered);
        nextBtn.disabled = userResponses[i] === null;
        const nextLabel = document.getElementById('btn-next-label');
        if (nextLabel)
            nextLabel.textContent = reviewingUnanswered
                ? 'Next missing'
                : canReviewFromLast
                  ? `Review ${remaining}`
                  : 'Next';

        const ready = !nextBtn.disabled && (userResponses[i] !== null || canReviewFromLast);
        nextBtn.classList.toggle('btn-primary', ready);
        nextBtn.classList.toggle('btn-secondary', !ready);
    }

    const submitBtn = document.getElementById('btn-submit-ocean');
    const hint = document.getElementById('submit-hint');
    if (submitBtn) {
        submitBtn.hidden = !showSubmit;
        submitBtn.disabled = !isComplete();
    }
    if (hint) {
        hint.textContent =
            reviewingUnanswered && userResponses[i] === null
                ? `${remaining} unanswered. Answer this question to continue.`
                : canReviewFromLast
                  ? `${remaining} unanswered. Review them before submitting.`
                  : '';
    }
}

function handleAnswer(score) {
    userResponses[currentQuestionIndex] = score;
    saveOceanProgress();
    loadQuestion();
}

// The "Saving your answers" notice is a window over the test, shown until the page moves on (or an error replaces it).
function setSavingModal(on) {
    const modal = document.getElementById('saving-modal');
    const box = document.getElementById('saving-modal-content');
    if (!modal || !box) return;
    modal.classList.toggle('modal-active', on);
    box.classList.toggle('modal-content-active', on);
    modal.setAttribute('aria-hidden', on ? 'false' : 'true');
    document.body.style.overflow = on ? 'hidden' : 'auto';
}

async function submitTestResults() {
    if (!isComplete()) {
        const missing = userResponses.indexOf(null);
        goToQuestion(missing);
        return;
    }
    hasSubmitted = true;

    setSavingModal(true);

    if (!supabaseClient) return;

    const { error } = await supabaseClient.rpc(
        STAFF ? 'submit_ocean_results_teacher' : 'submit_ocean_results',
        {
            p_responses: userResponses
        }
    );

    if (error) {
        setSavingModal(false);
        testContainer.innerHTML = `
            <div class="state-card">
                <h2>We couldn't save your answers</h2>
                <p>${escapeHTML(error.message)}</p>
                <p style="margin-top:12px">Your answers are still saved on this computer, so
                   nothing is lost — try again.</p>
                <button type="button" data-action="reload" class="btn btn-primary">Try again</button>
            </div>
        `;
        return;
    }

    clearOceanProgress();

    if (!STAFF) await finalizeStageTime('OCEAN');

    const next = isControlGroup(verifiedProfile) ? 'thank-you.html' : 'waiting-room.html';
    window.location.replace(STAFF ? TEACHER_DASHBOARD : next);
}

let isQuittingDeliberately = false;

function confirmQuit() {
    return new Promise((resolve) => {
        const modal = document.getElementById('quit-modal');
        const box = document.getElementById('quit-modal-content');
        const stayBtn = document.getElementById('quit-modal-stay');
        const leaveBtn = document.getElementById('quit-modal-leave');

        if (!modal || !box || !stayBtn || !leaveBtn) return resolve(true);

        const answered = answeredCount();
        const total = questions.length;
        const pct = Math.round((answered / total) * 100);

        const countEl = document.getElementById('quit-progress-count');
        const fillEl = document.getElementById('quit-progress-fill');
        if (countEl) countEl.textContent = `${answered} of ${total}`;
        if (fillEl) fillEl.style.width = `${pct}%`;

        modal.classList.add('modal-active');
        box.classList.add('modal-content-active');
        modal.setAttribute('aria-hidden', 'false');
        document.body.style.overflow = 'hidden';

        stayBtn.focus();

        const close = (result) => {
            modal.classList.remove('modal-active');
            box.classList.remove('modal-content-active');
            modal.setAttribute('aria-hidden', 'true');
            document.body.style.overflow = 'auto';

            stayBtn.removeEventListener('click', onStay);
            leaveBtn.removeEventListener('click', onLeave);
            modal.removeEventListener('click', onBackdrop);
            document.removeEventListener('keydown', onKey);

            resolve(result);
        };

        function onStay() {
            close(false);
        }
        function onLeave() {
            close(true);
        }
        function onBackdrop(e) {
            if (e.target === modal) close(false);
        }
        function onKey(e) {
            if (e.key === 'Escape') close(false);
            if (e.key === 'Tab') {
                const focusables = [stayBtn, leaveBtn];
                const i = focusables.indexOf(document.activeElement);
                if (i !== -1) {
                    e.preventDefault();
                    focusables[
                        (i + (e.shiftKey ? -1 : 1) + focusables.length) % focusables.length
                    ].focus();
                }
            }
        }

        stayBtn.addEventListener('click', onStay);
        leaveBtn.addEventListener('click', onLeave);
        modal.addEventListener('click', onBackdrop);
        document.addEventListener('keydown', onKey);
    });
}

function setupExitGuard() {
    document.querySelectorAll('a[href]').forEach((link) => {
        link.addEventListener('click', async (e) => {
            if (!isTestInProgress() || isQuittingDeliberately) return;

            e.preventDefault();
            const href = link.href;

            if (await confirmQuit()) {
                isQuittingDeliberately = true;
                window.location.href = href;
            }
        });
    });

    window.addEventListener('beforeunload', (e) => {
        if (!isTestInProgress() || isQuittingDeliberately) return;
        e.preventDefault();
        e.returnValue = '';
    });
}

document.addEventListener(
    'click',
    (e) => {
        const quit = e.target.closest && e.target.closest('#signout-btn');
        if (!quit) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        confirmQuit().then((leave) => {
            if (!leave) return;
            isQuittingDeliberately = true;
            quit.disabled = true;
            if (typeof executeForceLogout === 'function') executeForceLogout();
        });
    },
    true
);

checkAccessAndInit();

// onclick="" attribute: the site's Content-Security-Policy (_headers) forbids

document.addEventListener('click', (event) => {
    const control = event.target.closest('[data-action]');
    if (!control || control.disabled) return;
    const action = control.getAttribute('data-action');
    if (action === 'start') startTestDirectly();
    else if (action === 'reload') window.location.reload();
});
