(function () {
    'use strict';

    var Dash = window.PIADash;

    function renderProblem() {
        var p = Dash.state.problem;
        $('#problem-kicker').textContent = Dash.topicTitle(p.questionTopic);
        $('#problem-expression').textContent = p.question;
        renderSteps(true);
        Dash.paintHintButton();
    }
    Dash.renderProblem = renderProblem;

    function renderSteps(focus) {
        var p = Dash.state.problem;
        var box = $('#steps');
        box.textContent = '';

        for (var i = 0; i <= p.stepIndex && i < p.stepsTotal; i++) {
            box.appendChild(buildStep(i, p));
        }

        if (focus && Dash.problemOpen()) {
            var input = $('#step-input');
            if (input) {
                input.focus({ preventScroll: true });
                var card = input.closest('.step-card');
                if (card && card.scrollIntoView) {
                    card.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
                }
            }
        }
    }
    Dash.renderSteps = renderSteps;

    function lockedInput(value) {
        var input = Dash.el('input', 'solution-input');
        input.type = 'text';
        input.disabled = true;
        input.value = value || '';
        input.setAttribute('aria-label', 'Your accepted entry');
        var row = Dash.el('div', 'solution-input-row');
        row.appendChild(input);
        return row;
    }

    function buildStep(i, p) {
        var done = i < p.stepIndex || p.locked;
        var label = p.labels[i] || 'Step ' + (i + 1);
        var card = Dash.el('section', 'step-card' + (done ? ' correct' : ''));
        card.setAttribute('aria-label', 'Step ' + (i + 1) + ': ' + label);

        var head = Dash.el('div', 'step-header');
        head.appendChild(
            Dash.el(
                'div',
                'step-number-badge',
                done ? 'Completed' : 'Step ' + (i + 1) + ' of ' + p.stepsTotal
            )
        );
        head.appendChild(Dash.el('h3', 'step-title', 'Step ' + (i + 1) + ': ' + label));
        if (done) {
            head.appendChild(Dash.el('span', 'step-answer', '(' + ((p.doneSteps[i] || {}).text || '') + ')'));
        }
        card.appendChild(head);

        if (done) {
            var entry = p.doneSteps[i] || {};
            card.appendChild(Dash.el('div', 'solution-label', 'Your Step Solution'));
            card.appendChild(lockedInput(entry.text));
            if (entry.confirmed) {
                var conf = Dash.CONFIRM[kindOfLabel(label, p.questionTopic)];
                var again = Dash.el('div', 'conversion-confirmation');
                again.appendChild(Dash.el('div', 'solution-label', conf.label));
                again.appendChild(lockedInput(entry.confirmed));
                card.appendChild(again);
            }
            return card;
        }

        var confirming = p.stage === 'confirm';
        var conf2 = Dash.CONFIRM[p.confirmKind];

        if (confirming) {
            card.appendChild(Dash.el('div', 'solution-label', 'Your Step Solution'));
            card.appendChild(lockedInput(p.workText));
            card.appendChild(Dash.el('div', 'feedback-msg correct', 'Correct calculation.'));
        }

        var form = Dash.el('form', 'step-form' + (confirming ? ' conversion-confirmation' : ''));
        form.noValidate = true;
        form.addEventListener('submit', onStepSubmit);

        var labelEl = Dash.el(
            'label',
            'solution-label',
            confirming ? conf2.prompt : 'Your Step Solution'
        );
        labelEl.setAttribute('for', 'step-input');
        form.appendChild(labelEl);

        var row = Dash.el('div', 'solution-input-row');
        var input = Dash.el('input', 'solution-input');
        input.id = 'step-input';
        input.type = 'text';
        input.setAttribute('inputmode', 'text');
        input.setAttribute('autocomplete', 'off');
        input.setAttribute('autocapitalize', 'off');
        input.setAttribute('spellcheck', 'false');
        input.setAttribute('maxlength', '60');
        input.setAttribute(
            'placeholder',
            confirming ? conf2.placeholder : Dash.WORK_PLACEHOLDER[Dash.workKind(p)]
        );
        input.setAttribute('aria-describedby', 'step-feedback');
        row.appendChild(input);
        form.appendChild(row);

        var footer = Dash.el('div', 'step-footer');
        var feedback = Dash.el('div', 'feedback-msg', '');
        feedback.id = 'step-feedback';
        feedback.setAttribute('role', 'status');
        feedback.setAttribute('aria-live', 'polite');
        footer.appendChild(feedback);
        var submit = Dash.el('button', 'btn-check-step', confirming ? conf2.button : 'Submit Step');
        submit.type = 'submit';
        submit.id = 'step-submit';
        footer.appendChild(submit);
        form.appendChild(footer);
        card.appendChild(form);
        return card;
    }

    function kindOfLabel(label, topic) {
        if (label !== 'Conversion') {
            return 'number';
        }
        return topic === 1 ? 'decimal' : 'percentage';
    }

    function setStepFeedback(text, tone) {
        var node = $('#step-feedback');
        if (!node) {
            return;
        }
        node.textContent = text || '';
        node.classList.toggle('wrong', tone === 'wrong');
        node.classList.toggle('correct', tone === 'correct');
        node.classList.toggle('neutral', tone === 'neutral');
        if (tone === 'wrong') {
            node.classList.remove('shake');
            void node.offsetWidth;
            node.classList.add('shake');
        }
    }
    Dash.setStepFeedback = setStepFeedback;

    function onStepSubmit(event) {
        event.preventDefault();
        submitStep();
    }

    async function submitStep() {
        if (Dash.state.submitting || !Dash.problemOpen()) {
            return;
        }

        var input = $('#step-input');
        if (!input) {
            return;
        }
        var raw = input.value.trim();

        if (!raw) {
            setStepFeedback('Type your answer first.', 'neutral');
            input.focus();
            return;
        }

        Dash.state.submitting = true;
        input.disabled = true;
        var release = Dash.setBusy($('#step-submit'), 'Checking…');

        var res;
        try {
            res = await sb.rpc('check_step_answer', {
                p_session_id: Dash.state.sessionId,
                p_problem_id: Dash.state.problem.id,
                p_submitted: raw
            });
        } catch (err) {
            res = { error: err };
        }

        Dash.state.submitting = false;
        release();

        if (res.error || !res.data || !res.data.state) {
            console.error('Answer check failed:', res.error && res.error.message);
            input.disabled = false;
            setStepFeedback('Could not reach the server. Please try again.', 'wrong');
            input.select();
            return;
        }

        Dash.onStepResult(res.data, raw, input);
    }
})();
