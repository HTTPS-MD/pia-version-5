/* Global variables */
let selectedChar = null;
let isLockedIn = false;

let verifiedEmail = null;

async function enforceStageLock() {
    const profile = await enforceStudentStage('char');
    if (!profile) return;
    verifiedEmail = profile.email;
    startStageHeartbeat('Character Selection');
}

enforceStageLock();

let lines = [];

function showPose() {
    if (selectedChar) {
        const art = '../../assets/images/tutors/' + selectedChar + '/default.webp';
        const reducedMotion = window.matchMedia &&
            window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        document.getElementById('preview-bg-img').src =
            reducedMotion ? art.replace(/\.webp$/, '-still.webp') : art;
    }
    if (lines.length) {
        document.getElementById('preview-desc').textContent = lines[0];
    }
}

function previewCharacter(element) {
    if (isLockedIn) return;

    document.querySelectorAll('.persona-card').forEach((card) => {
        card.classList.remove('selected');
        card.setAttribute('aria-pressed', 'false');
    });

    element.classList.add('selected');
    element.setAttribute('aria-pressed', 'true');

    selectedChar = element.getAttribute('data-character');
    const name = element.getAttribute('data-name');
    lines = (element.getAttribute('data-lines') || '').split('|').filter(Boolean);

    document.getElementById('preview-name').textContent = name;
    document.getElementById('pick-tag').textContent = element.getAttribute('data-tag') || '';
    document.getElementById('pick-more').textContent = element.getAttribute('data-more') || '';
    document.getElementById('pick-hello').textContent = 'Say hi to ' + name + '!';
    document.getElementById('pick-bubble').hidden = false;
    document.getElementById('preview-card').classList.add('has-pick');
    showPose();

    const lockBtn = document.getElementById('lock-in-btn');
    lockBtn.hidden = false;
    lockBtn.textContent = 'Choose ' + name;
    lockBtn.disabled = false;
}

let confirmReturnFocus = null;

function confirmModalKeys(e) {
    const modal = document.getElementById('confirm-modal');
    if (!modal || !modal.classList.contains('modal-active')) return;
    if (e.key === 'Escape') {
        e.preventDefault();
        closeConfirmModal();
        return;
    }
    if (e.key !== 'Tab') return;
    const nodes = Array.from(modal.querySelectorAll('button:not([disabled])'));
    if (!nodes.length) return;
    const first = nodes[0],
        last = nodes[nodes.length - 1];
    if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first.focus();
    }
}

function openConfirmModal() {
    if (!selectedChar || isLockedIn) return;
    const modal = document.getElementById('confirm-modal');
    const content = document.getElementById('modal-content');

    confirmReturnFocus = document.activeElement;
    modal.classList.add('modal-active');
    content.classList.add('modal-content-active');
    document.addEventListener('keydown', confirmModalKeys);
    const safe = modal.querySelector('.modal-foot [data-action="close"]');
    if (safe) safe.focus({ preventScroll: true });
}

function closeConfirmModal() {
    const modal = document.getElementById('confirm-modal');
    const content = document.getElementById('modal-content');

    modal.classList.remove('modal-active');
    content.classList.remove('modal-content-active');
    document.removeEventListener('keydown', confirmModalKeys);
    if (confirmReturnFocus && confirmReturnFocus.focus && !confirmReturnFocus.disabled) {
        confirmReturnFocus.focus({ preventScroll: true });
    }
    confirmReturnFocus = null;
}

async function finalLockIn() {
    if (!selectedChar) return;
    if (!verifiedEmail) return;

    const lockBtn = document.getElementById('lock-in-btn');
    if (lockBtn) {
        if (lockBtn.dataset.busy === '1') return;
        lockBtn.dataset.busy = '1';
        lockBtn.disabled = true;
    }

    const { error } = await supabaseClient
        .from('profiles')
        .update({ selected_character: selectedChar })
        .eq('email', verifiedEmail);

    if (error) {
        const status = document.getElementById('status-text');
        if (status) {
            status.textContent = 'Not saved. Please try again.';
            status.style.color = 'var(--danger)';
        }
        const btn = document.getElementById('lock-in-btn');
        if (btn) {
            btn.disabled = false;
            btn.textContent = 'Try again';
        }
        closeConfirmModal();
        console.error('Could not save selection:', error.message);
        return;
    }

    localStorage.setItem('selected_character', selectedChar);

    await finalizeStageTime('Character Selection');

    closeConfirmModal();

    isLockedIn = true;
    const statusEl = document.getElementById('status-text');
    statusEl.textContent = 'Locked in!';
    statusEl.style.color = '';
    statusEl.classList.add('is-done');

    const name = document.getElementById('preview-name').textContent;
    document.getElementById('pick-hello').textContent = 'You picked ' + name + '!';
    document.getElementById('preview-desc').textContent = 'Great choice! Let’s do this together.';
    document.getElementById('pick-scene').classList.add('is-locked');

    document.querySelectorAll('.persona-card').forEach((card) => {
        card.style.pointerEvents = 'none';
        card.disabled = true;
    });

    document.getElementById('lock-in-btn').style.display = 'none';

    // Let the student see the pick for a moment, then on to tutoring, or the waiting room if it is not open yet.
    setTimeout(goOn, LOCK_IN_PAUSE_MS);
}

const LOCK_IN_PAUSE_MS = 2000;

async function goOn() {
    const { data } = await supabaseClient.rpc('set_student_stage', { p_stage: 'Tutoring Dashboard' });
    window.location.href = data && data.granted ? 'student-dashboard.html' : 'waiting-room.html';
}

if (supabaseClient) {
    registerChannel('realtime-char-lock', (ch) =>
        ch
            .on(
                'postgres_changes',
                {
                    event: 'UPDATE',
                    schema: 'public',
                    table: 'settings',
                    filter: `key=eq.stage_char`
                },
                (payload) => {
                    const isOpen = payload.new.value === true || payload.new.value === 'true';
                    if (!isOpen) {
                        window.location.href = 'waiting-room.html';
                    }
                }
            )
            .subscribe()
    );
}

// the site's Content-Security-Policy (_headers) forbids inline script, and an

const ACTIONS = {
    confirm: openConfirmModal,
    close: closeConfirmModal,
    lock: finalLockIn
};

document.addEventListener('click', (event) => {
    const card = event.target.closest('.persona-card');
    if (card) {
        previewCharacter(card);
        return;
    }

    const control = event.target.closest('[data-action]');
    if (!control || control.disabled) return;
    const run = ACTIONS[control.getAttribute('data-action')];
    if (run) run();
});

(function wireArtFallback() {
    function monogram(name) {
        return (
            (name || 'PIA')
                .replace(/^PIA\s*/i, '')
                .slice(0, 2)
                .toUpperCase() || 'PIA'
        );
    }

    document.querySelectorAll('.persona-card').forEach(function (card) {
        var img = card.querySelector('img');
        var box = card.querySelector('.persona-thumb');
        if (!img || !box) {
            return;
        }
        function useFallbackOrMonogram() {
            var fallback = card.getAttribute('data-fallback-img');
            if (fallback && img.getAttribute('src') !== fallback) {
                img.src = fallback;
            } else {
                box.setAttribute('data-mono', monogram(card.getAttribute('data-name')));
            }
        }
        img.addEventListener('error', useFallbackOrMonogram);
        if (img.complete && img.naturalWidth === 0) {
            useFallbackOrMonogram();
        }
    });

    var previewImg = document.getElementById('preview-bg-img');
    previewImg.addEventListener('error', function () {
        var chosen = document.querySelector('.persona-card.selected');
        var fallback = chosen && chosen.getAttribute('data-fallback-img');
        if (fallback && previewImg.getAttribute('src') !== fallback) {
            previewImg.src = fallback;
        } else {
            previewImg.style.visibility = 'hidden';
        }
    });
    previewImg.addEventListener('load', function () {
        previewImg.style.visibility = '';
    });
})();

// start with the first tutor shown, so the stage is never empty
const firstTutor = document.querySelector('.persona-card');
if (firstTutor) previewCharacter(firstTutor);
