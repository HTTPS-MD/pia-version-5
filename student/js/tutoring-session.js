/*
 * Tutoring session.
 * Checks that tutoring is open, starts or resumes a session and loads the next problem.
 */
(function () {
    'use strict';

    var Dash = window.PIADash;

    var POLL_MS = Number(window.PIA_TUTORING_POLL_MS) || 5000;

    function paintStartClosed(closed) {
        var btn = $('#start-btn'),
            lede = $('#start-lede');
        if (closed) {
            if (!Dash.state.startLede) {
                Dash.state.startLede = lede.textContent;
            }
            btn.disabled = true;

            lede.textContent = Dash.state.notOpenYet
                ? 'Tutoring has not opened yet. Please wait for your admin to open it.'
                : 'Tutoring is closed right now. Please wait for your admin to open it again.';
        } else if (Dash.state.startLede) {
            lede.textContent = Dash.state.startLede;
            Dash.state.startLede = '';
            btn.disabled = Dash.state.startBlocked;
        }
    }

    async function reopenSession() {
        Dash.state.expired = false;
        Dash.closeModal('modal-time');
        $('#time-announce').textContent = '';
        Dash.speak('Tutoring is open again. Let’s continue!', 'happy');
        Dash.state.problem = null;
        await nextProblem();
    }

    async function checkTutoring() {
        if (Dash.state.checking || !sb) {
            return;
        }
        Dash.state.checking = true;
        var res = null;
        try {
            res = await sb.rpc('tutoring_status');
        } catch (e) {
            res = null;
        }
        Dash.state.checking = false;
        if (!res || res.error || !res.data) {
            return;
        }

        clearTimeout(Dash.state.closeTimer);

        var left = Number(
            res.data.seconds_to_close != null ? res.data.seconds_to_close : res.data.seconds_to_open
        );
        var nextAt =
            res.data.seconds_to_close != null
                ? res.data.seconds_to_close
                : res.data.seconds_to_open;
        if (nextAt != null && isFinite(left) && left >= 0) {
            Dash.state.closeTimer = setTimeout(checkTutoring, Math.min(left, 3600) * 1000 + 300);
        }

        var closed = res.data.closed === true;
        var notYet = res.data.not_open_yet === true;
        if (
            notYet !== Dash.state.notOpenYet &&
            closed === Dash.state.closed &&
            !Dash.state.inSession
        ) {
            Dash.state.notOpenYet = notYet;
            paintStartClosed(closed);
        }
        Dash.state.notOpenYet = notYet;
        if (
            closed === Dash.state.closed &&
            (closed === Dash.state.expired || !Dash.state.inSession)
        ) {
            if (!Dash.state.inSession) {
                paintStartClosed(closed);
            }
            return;
        }
        Dash.state.closed = closed;
        if (closed) {
            if (Dash.state.inSession) {
                Dash.expire();
            } else {
                paintStartClosed(true);
            }
        } else if (Dash.state.expired) {
            await reopenSession();
        } else {
            paintStartClosed(false);
        }
    }
    Dash.checkTutoring = checkTutoring;

    function watchTutoring() {
        setInterval(checkTutoring, POLL_MS);
        document.addEventListener('visibilitychange', function () {
            if (!document.hidden) {
                checkTutoring();
            }
        });
    }
    Dash.watchTutoring = watchTutoring;

    function noQuestions() {
        Dash.state.bankEmpty = true;
        $('#problem-kicker').textContent = 'No problems yet';
        $('#problem-expression').textContent =
            'No configured questions are available. Please ask your admin to check the question bank.';
        $('#steps').textContent = '';
        Dash.speak(null, 'default');
    }
    Dash.noQuestions = noQuestions;

    async function startOrResume() {
        var res = await sb.rpc('resume_or_start_game_session');

        if (res.error || !res.data || !res.data.session_id) {
            console.error('Could not start/resume session:', res.error && res.error.message);
            Dash.toast('Could not start', 'Please check your connection and try again.', 'danger');
            return false;
        }

        applySession(res.data);
        return true;
    }
    Dash.startOrResume = startOrResume;

    function applySession(d) {
        Dash.state.sessionId = d.session_id;
        Dash.state.answered = Number(d.problems_answered) || 0;
        Dash.state.clean = Number(d.correct_count) || 0;
        Dash.state.topic = Number(d.topic) || 1;
        Dash.state.streak = Number(d.consecutive_correct) || 0;
    }
    Dash.applySession = applySession;

    function applyQuestion(d) {
        var prev = Dash.state.problem;
        var sameQuestion = prev && prev.id === d.problem_id;
        Dash.state.problem = {
            id: d.problem_id,
            number: Number(d.problem_number) || Dash.state.answered + 1,
            question: String(d.question || ''),
            topic: Number(d.topic) || Dash.state.topic,
            questionTopic: Number(d.question_topic) || Number(d.topic) || 1,
            stepsTotal: Number(d.steps_total) || 0,
            labels: Array.isArray(d.step_labels) ? d.step_labels : [],
            stepIndex: Number(d.current_step) || 0,
            stage: d.stage === 'confirm' ? 'confirm' : 'work',
            confirmKind: Dash.CONFIRM[d.confirm_kind] ? d.confirm_kind : 'number',
            workText: d.work_text || '',
            doneSteps: Array.isArray(d.done_steps) ? d.done_steps : [],
            hintUnlocked: d.hint_unlocked === true,
            hintTier: Number(d.hint_tier) || 0,
            locked: d.locked === true,
            hint: sameQuestion ? prev.hint : null
        };
        Dash.state.topic = Dash.state.problem.topic;
    }
    Dash.applyQuestion = applyQuestion;

    async function nextProblem() {
        if (Dash.state.ended) {
            return;
        }

        var res = await sb.rpc('serve_next_step_question', { p_session_id: Dash.state.sessionId });

        if (res.error || !res.data) {
            console.error('Could not load the next question:', res.error && res.error.message);
            Dash.speak('I could not reach the server. Trying again…', 'default');
            setTimeout(nextProblem, 4000);
            return;
        }

        var d = res.data;
        Dash.syncClock(d.clock);
        if (d.done) {
            return noQuestions();
        }
        if (d.pending_offer) {
            return Dash.showOffer(d.pending_offer);
        }

        applyQuestion(d);
        Dash.state.stepWrong = 0;
        Dash.state.stepStartedAt = Date.now();
        Dash.renderProblem();
        Dash.syncProgress();
        if (Dash.state.expired) {
            Dash.lockForExpiry();
        }

        if (Dash.state.problem.locked) {
            Dash.finishProblem();
        }
    }
    Dash.nextProblem = nextProblem;
})();
