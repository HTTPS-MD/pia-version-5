(function () {
    'use strict';

    var Dash = window.PIADash;

    function problemOpen() {
        return !!Dash.state.problem && !Dash.state.problem.locked && Dash.state.preview === null;
    }
    Dash.problemOpen = problemOpen;

    function paintHintButton() {
        var btn = $('#hint-btn');
        var open =
            !!Dash.state.problem &&
            !Dash.state.problem.locked &&
            Dash.state.problem.hintUnlocked &&
            Dash.state.preview === null &&
            !Dash.state.expired;
        btn.classList.toggle('is-away', !open);
        btn.disabled = !open || Dash.state.hinting;

        var tier = Dash.state.problem && Dash.state.problem.hint;
        $('#hint-tier-label').textContent = tier
            ? '(Tier ' + tier.tier + '/' + tier.total + ')'
            : '';
    }
    Dash.paintHintButton = paintHintButton;

    function paintSolved() {
        var list = $('#solved-list');
        list.textContent = '';
        if (!Dash.state.solved.length) {
            list.appendChild(Dash.el('div', 'q-history-empty', 'No solved questions yet'));
            return;
        }
        Dash.state.solved.forEach(function (q, idx) {
            var btn = Dash.el(
                'div',
                'q-btn active' + (Dash.state.preview === idx ? ' previewing' : '')
            );
            btn.setAttribute('role', 'button');
            btn.setAttribute('tabindex', '0');
            btn.setAttribute('title', 'Click to preview this solved question');
            btn.setAttribute('aria-label', 'Preview solved question: ' + q.question);
            if (Dash.state.preview === idx) {
                btn.setAttribute('aria-pressed', 'true');
            }
            btn.appendChild(Dash.el('span', 'q-btn-equation', q.question));
            btn.addEventListener('click', function () {
                openPreview(idx);
            });
            btn.addEventListener('keydown', function (e) {
                if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    openPreview(idx);
                }
            });
            list.appendChild(btn);
        });
    }
    Dash.paintSolved = paintSolved;

    function paintErrors() {
        var list = $('#error-list');
        list.textContent = '';
        Dash.state.errors.slice(-5).forEach(function (e) {
            list.appendChild(Dash.el('div', 'history-item', e));
        });
    }
    Dash.paintErrors = paintErrors;

    function openPreview(idx) {
        var q = Dash.state.solved[idx];
        if (!q || Dash.state.expired) {
            return;
        }
        Dash.state.preview = idx;
        $('#center-panel').classList.add('solved-preview-mode');
        $('#problem-kicker').textContent = 'Solved Review • ' + Dash.topicTitle(q.topic);
        $('#problem-expression').textContent = q.question;

        var box = $('#steps');
        box.textContent = '';
        var bar = Dash.el('div', 'workspace-preview-toolbar');
        bar.appendChild(Dash.el('div', 'workspace-preview-heading', 'Your solved work'));
        var back = Dash.el('button', 'workspace-preview-back', '← Back to current question');
        back.type = 'button';
        back.id = 'preview-back';
        back.addEventListener('click', closePreview);
        bar.appendChild(back);
        box.appendChild(bar);

        q.steps.forEach(function (st) {
            var block = Dash.el('div', 'workspace-preview-step');
            block.appendChild(Dash.el('div', 'workspace-preview-step-title', st.title));
            block.appendChild(Dash.el('div', 'workspace-preview-answer-label', 'Your answer'));
            block.appendChild(
                Dash.el(
                    'div',
                    'workspace-preview-answer',
                    st.confirmed ? st.text + ' → ' + st.confirmed : st.text
                )
            );
            box.appendChild(block);
        });

        paintSolved();
        paintHintButton();
        back.focus({ preventScroll: true });
        $('#center-panel').scrollTop = 0;
    }

    function closePreview() {
        if (Dash.state.preview === null) {
            return;
        }
        Dash.state.preview = null;
        $('#center-panel').classList.remove('solved-preview-mode');
        paintSolved();
        if (Dash.state.problem) {
            Dash.renderProblem();
        } else if (Dash.state.bankEmpty) {
            Dash.noQuestions();
        }
    }
    Dash.closePreview = closePreview;

    function syncClock(c) {
        if (!c) {
            return;
        }
        if ((c.closed === true || c.expired === true) && Dash.state.inSession) {
            expire();
        }
    }
    Dash.syncClock = syncClock;

    function lockForExpiry() {
        var input = $('#step-input'),
            submit = $('#step-submit');
        if (input) {
            input.disabled = true;
        }
        if (submit) {
            submit.disabled = true;
        }
        $('#hint-btn').disabled = true;
    }
    Dash.lockForExpiry = lockForExpiry;

    function expire() {
        if (Dash.state.expired) {
            return;
        }
        closePreview();
        Dash.state.expired = true;
        Dash.state.closed = true;
        lockForExpiry();
        Dash.speak('Tutoring is closed for now. Thank you for your hard work!', 'default');
        $('#time-announce').textContent = 'Tutoring is closed.';
        Dash.openModal('modal-time');
    }
    Dash.expire = expire;
})();
