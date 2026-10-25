/*
 * Answers and hints.
 * What happens after an answer, asking for a hint, finishing a problem and the extra-practice offer.
 */
(function () {
    'use strict';

    var Dash = window.PIADash;

    async function refreshProfile() {
        var mine = ++Dash.profileCall;
        var res;
        try {
            res = await sb.functions.invoke('learning-profile', {
                body: { session_id: Dash.state.sessionId }
            });
        } catch (e) {
            return;
        }
        if (mine !== Dash.profileCall || !res || res.error || !res.data) {
            return;
        }
        var target = Dash.PROFILE_ORDER.indexOf(res.data.profile);
        var now = Dash.PROFILE_ORDER.indexOf(Dash.LEARNING_PROFILE);
        if (target < 0 || now < 0 || target === now) {
            return;
        }
        Dash.LEARNING_PROFILE = Dash.PROFILE_ORDER[now + (target > now ? 1 : -1)];
    }

    function onStepResult(d, raw, input) {
        var p = Dash.state.problem;
        var stepNo = p.stepIndex + 1;
        var wasConfirming = p.stage === 'confirm';
        var kind = p.confirmKind;
        var outcome = d.outcome;

        Dash.syncClock(d.clock);
        Dash.applyQuestion(d.state);
        input.disabled = false;
        refreshProfile();

        if (outcome === 'time_expired') {
            Dash.renderSteps(false);
            Dash.lockForExpiry();
            return;
        }

        if (outcome === 'locked') {
            Dash.renderSteps(false);
            Dash.paintHintButton();
            if (Dash.state.problem.locked) {
                finishProblem();
            }
            return;
        }

        if (outcome === 'wrong' || outcome === 'format_error') {
            Dash.state.stepWrong++;
            Dash.state.correctRun = 0;

            if (outcome === 'format_error') {
                Dash.setStepFeedback(Dash.CONFIRM[kind].error, 'wrong');
                Dash.reactToWrong(Dash.reaction('finalFormatError', 'wrong'));
                Dash.state.errors.push('Step ' + stepNo + ': Final-answer error on "' + raw + '"');
            } else {
                Dash.setStepFeedback('Incorrect answer. Try again.', 'wrong');
                Dash.reactToWrong(
                    Dash.reaction(
                        Number(d.state.wrong_streak) >= 2 ? 'wrongRepeated' : 'wrongFirst',
                        'wrong'
                    )
                );
                Dash.state.errors.push('Step ' + stepNo + ': Error on "' + raw + '"');
            }
            Dash.paintErrors();
            Dash.paintHintButton();
            input.select();
            return;
        }

        if (outcome === 'needs_final') {
            Dash.state.correctRun++;
            Dash.state.problem.hint = null;
            Dash.speak(
                (
                    Dash.reaction('correctWorkNeedsFinal', 'correct') +
                    ' ' +
                    Dash.CONFIRM[Dash.state.problem.confirmKind].prompt
                ).trim(),
                'happy'
            );
            Dash.renderSteps(true);
            Dash.paintHintButton();
            return;
        }

        Dash.state.correctRun++;
        Dash.state.problem.hint = null;
        var kindOfReaction =
            Dash.state.stepWrong > 0
                ? 'correctAfterStruggle'
                : !wasConfirming && Date.now() - Dash.state.stepStartedAt <= Dash.FAST_CORRECT_MS
                  ? 'fastCorrect'
                  : Dash.state.correctRun >= Dash.STREAK_FOR_PRAISE
                    ? 'correctStreak'
                    : 'correctFirstTry';

        Dash.speak(
            Dash.reaction(kindOfReaction, 'correct'),
            kindOfReaction === 'fastCorrect' || kindOfReaction === 'correctStreak'
                ? 'excited'
                : 'happy'
        );

        Dash.state.stepWrong = 0;
        Dash.state.stepStartedAt = Date.now();
        Dash.renderSteps(outcome !== 'question_done');
        Dash.paintHintButton();

        if (outcome === 'question_done') {
            var q = Dash.state.problem;
            Dash.state.solved.push({
                number: q.number,
                topic: q.questionTopic,
                question: q.question,
                steps: q.doneSteps.map(function (s, n) {
                    return {
                        title: 'Step ' + (n + 1) + ': ' + (q.labels[n] || 'Step ' + (n + 1)),
                        text: s.text,
                        confirmed: s.confirmed
                    };
                })
            });
            Dash.paintSolved();
            setTimeout(finishProblem, 900);
        }
    }
    Dash.onStepResult = onStepResult;

    async function handleHint() {
        var btn = $('#hint-btn');
        if (btn.disabled || !Dash.problemOpen() || Dash.state.hinting) {
            return;
        }
        Dash.state.hinting = true;
        btn.disabled = true;

        var res = await sb.rpc('consume_step_hint', {
            p_session_id: Dash.state.sessionId,
            p_problem_id: Dash.state.problem.id
        });
        Dash.state.hinting = false;

        if (res.error || !res.data || !res.data.state) {
            Dash.paintHintButton();
            Dash.setStepFeedback('Could not load a hint. Please try again.', 'wrong');
            return;
        }

        var d = res.data;
        Dash.syncClock(d.clock);
        refreshProfile();
        var keep = Dash.state.problem.hint;
        Dash.applyQuestion(d.state);
        Dash.state.problem.hint = keep;

        if (d.hint) {
            Dash.state.problem.hint = {
                text: d.hint.text,
                tier: d.hint.tier,
                total: d.hint.tiers_total,
                step: d.hint.step
            };
            Dash.state.hintsUsedTotal++;

            var example = window.PIAHintBoard
                ? window.PIAHintBoard.parseExample(d.hint.text)
                : null;
            if (example) {
                Dash.speak(Dash.EXAMPLE_INTRO, 'thinking');
                window.PIAHintBoard.open(example, {
                    host: $('#status-msg'),
                    root: $('.video-copy-layer'),
                    intro: Dash.EXAMPLE_INTRO
                });
            } else {
                Dash.speak(
                    (Dash.reaction('hintRequested', 'hint') + ' ' + d.hint.text).trim(),
                    'thinking'
                );
            }

            syncProgress();
        }
        Dash.paintHintButton();

        var input = $('#step-input');
        if (input) {
            input.focus({ preventScroll: true });
        }
    }
    Dash.handleHint = handleHint;

    async function finishProblem() {
        if (Dash.state.finishing || Dash.state.ended) {
            return;
        }
        Dash.state.finishing = true;

        var res = await sb.rpc('finish_step_question', {
            p_session_id: Dash.state.sessionId,
            p_problem_id: Dash.state.problem.id
        });
        Dash.state.finishing = false;

        if (res.error || !res.data) {
            console.error('Failed to record result:', res.error && res.error.message);
            Dash.speak('Saving your work… one moment.', 'default');
            setTimeout(finishProblem, 3000);
            return;
        }

        var r = res.data;
        Dash.state.answered = Number(r.problems_answered) || Dash.state.answered + 1;
        if (r.is_correct === true) {
            Dash.state.clean++;
        }
        Dash.state.streak = Number(r.streak) || 0;
        syncProgress();

        if (r.offer) {
            r.offer.problem_id = r.offer.problem_id || Dash.state.problem.id;
            return showOffer(r.offer);
        }
        Dash.nextProblem();
    }
    Dash.finishProblem = finishProblem;

    function showOffer(offer) {
        var up = offer.type === 'up';
        var target = Number(offer.target_topic) || Dash.state.topic;
        var text = Dash.clean(
            Dash.pickLine(
                'adapt:' + Dash.tutorKey + ':' + offer.type,
                Dash.tutor.adaptive[up ? 'upgrade' : 'downgrade']
            ).replace(/\{topic\}/g, Dash.topicOf(target).name)
        );

        Dash.closePreview();
        $('#offer-text').textContent = text;
        $('#offer-destination').textContent =
            (up ? 'Available progression: ' : 'Recommended review: ') + Dash.topicOf(target).name;

        var img = $('#offer-img');
        Dash.guardImage(img);
        img.setAttribute('src', Dash.moodSrc(up ? 'excited' : 'default'));
        img.setAttribute('alt', '');

        Dash.speak(null, up ? 'excited' : 'default');
        Dash.state.pendingOffer = offer;
        Dash.state.offering = false;
        Dash.openModal('modal-offer');
    }
    Dash.showOffer = showOffer;

    async function answerOffer(accept) {
        if (Dash.state.offering || !Dash.state.pendingOffer) {
            return;
        }
        Dash.state.offering = true;
        var buttons = [$('#offer-accept'), $('#offer-stay')];
        buttons.forEach(function (b) {
            b.disabled = true;
        });

        var res = await sb.rpc('respond_topic_offer', {
            p_session_id: Dash.state.sessionId,
            p_problem_id:
                Dash.state.pendingOffer.problem_id || (Dash.state.problem && Dash.state.problem.id),
            p_accept: accept
        });

        buttons.forEach(function (b) {
            b.disabled = false;
        });
        Dash.state.offering = false;

        if (res.error || !res.data) {
            console.error('Could not save the choice:', res.error && res.error.message);
            Dash.toast('Could not save your choice', 'Please try again.', 'danger');
            return;
        }

        Dash.state.topic = Number(res.data.topic) || Dash.state.topic;
        Dash.state.pendingOffer = null;
        Dash.closeModal('modal-offer');
        syncProgress();
        Dash.nextProblem();
    }
    Dash.answerOffer = answerOffer;

    async function syncProgress() {
        if (!Dash.state.email || Dash.state.ended) {
            return;
        }
        var p = Dash.state.problem;
        await sb
            .from('profiles')
            .update({
                current_problem: p ? p.number : Dash.state.answered + 1,
                current_difficulty:
                    'Topic ' + Dash.state.topic + ' · ' + Dash.topicOf(Dash.state.topic).short,
                hints_used: Dash.state.hintsUsedTotal,
                consecutive_correct: Dash.state.streak
            })
            .eq('email', Dash.state.email);
    }
    Dash.syncProgress = syncProgress;
})();
