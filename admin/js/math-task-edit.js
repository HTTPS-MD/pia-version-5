/*
 * Math task bank (2 of 3).
 * Row actions, delete, bulk points, the question editor and the auto-generator.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function qbRow(item, index) {
        var n = index + 1;
        var tr = document.createElement('tr');
        tr.className = 'qb-row is-clickable';
        tr.tabIndex = 0;
        tr.setAttribute('data-id', String(item.id));

        var tdQ = Admin.qbCell('qb-cell-q');
        var q = document.createElement('p');
        q.className = 'qb-q';
        q.id = 'qb-q-' + item.id;
        q.textContent = item.q || 'Untitled question';
        q.title = item.q || '';
        tdQ.append(q);

        tr.append(
            tdQ,
            qbValueCell(item.final || '—', 'Final answer', 'qb-cell-answer'),
            qbValueCell(String(item.points), 'Points', 'qb-cell-points tnum')
        );
        return tr;
    }
    Admin.qbRow = qbRow;

    function qbValueCell(value, label, cellClass) {
        var td = Admin.qbCell(cellClass);
        var heading = document.createElement('span');
        heading.className = 'qb-cell-label';
        heading.textContent = label;
        var body = document.createElement('span');
        body.className = 'qb-cell-value';
        body.textContent = value;
        td.append(heading, body);
        return td;
    }

    function qbSkeletonRow() {
        var tr = document.createElement('tr');
        tr.className = 'qb-row';
        tr.setAttribute('aria-hidden', 'true');
        tr.innerHTML =
            '<td class="qb-cell-q">' +
            '<div class="qb-q qb-skel-q"><span class="skeleton skeleton-line" style="width:92%"></span>' +
            '<span class="skeleton skeleton-line" style="width:64%"></span></div>' +
            '</td>' +
            '<td class="qb-cell-answer"><span class="qb-cell-label">&nbsp;</span><span class="skeleton qb-skel-field"></span></td>' +
            '<td class="qb-cell-points"><span class="qb-cell-label">&nbsp;</span><span class="skeleton qb-skel-field"></span></td>';
        return tr;
    }
    Admin.qbSkeletonRow = qbSkeletonRow;

    function renderQbRules() {
        var ready = Admin.qb.status === 'ready';
        var rules = Admin.qb.rules[Admin.qb.topic];
        var range = $('#qb-mastery');

        range.value = String(rules.mastery);
        qbPaintRange();
        $('#qb-min-questions').value = rules.minQuestions == null ? '' : String(rules.minQuestions);
        $('#qb-max-errors').value = rules.maxErrors == null ? '' : String(rules.maxErrors);

        ['#qb-mastery', '#qb-min-questions', '#qb-max-errors'].forEach(function (sel) {
            $(sel).disabled = !ready;
        });

        var sc = Admin.qb.scoring,
            sActive = document.activeElement && document.activeElement.id;
        [
            ['#qb-sc-wrong', 'wrong'],
            ['#qb-sc-hint', 'hint'],
            ['#qb-sc-fast', 'fast'],
            ['#qb-sc-secs', 'secs'],
            ['#qb-sc-min', 'min'],
            ['#qb-sc-repeat-pct', 'repeatPct']
        ].forEach(function (pair) {
            if (sActive !== pair[0].slice(1)) {
                $(pair[0]).value = String(sc[pair[1]]);
            }
            $(pair[0]).disabled = !ready || !Admin.qb.hasScoring;
        });
        $('#qb-sc-speed').checked = !!sc.speed;
        $('#qb-sc-repeat').checked = !!sc.repeatOn;
        $('#qb-sc-speed').disabled = !ready || !Admin.qb.hasScoring;
        $('#qb-sc-repeat').disabled = !ready || !Admin.qb.hasScoring;
        $('#qb-sc-fast').disabled = !ready || !Admin.qb.hasScoring || !sc.speed;
        $('#qb-sc-secs').disabled = !ready || !Admin.qb.hasScoring || !sc.speed;
        $('#qb-sc-repeat-pct').disabled = !ready || !Admin.qb.hasScoring || !sc.repeatOn;
        $('#qb-sc-note').textContent = Admin.qb.hasScoring
            ? 'Saved with the rules above. A change applies to questions finished from then on; scores already earned are never rewritten.'
            : 'Available after the scoring database update.';
        Admin.qbRenderScoringExample();
        $('#qb-config-save').disabled = !ready || Admin.qb.busy.config;
        $('#qb-dirty').classList.toggle('is-on', Admin.qb.dirty);
    }
    Admin.renderQbRules = renderQbRules;

    function qbPaintRange() {
        var range = $('#qb-mastery');
        var min = Admin.toInt(range.min, 50),
            max = Admin.toInt(range.max, 100),
            val = Admin.toInt(range.value, 80);
        range.style.setProperty('--qb-fill', ((val - min) / (max - min)) * 100 + '%');
        $('#qb-mastery-out').textContent = val + '%';
        range.setAttribute('aria-valuetext', val + ' percent');
    }
    Admin.qbPaintRange = qbPaintRange;

    function qbSwitchTopic(topic) {
        if (!Admin.QB_TOPICS[topic] || topic === Admin.qb.topic) {
            return;
        }
        Admin.qb.topic = topic;
        Admin.clearFormErrors('qb-config-form');
        Admin.renderQbAll();
    }
    Admin.qbSwitchTopic = qbSwitchTopic;

    function qbRowEl(id) {
        return $('#qb-tbody .qb-row[data-id="' + id + '"]');
    }

    function qbShort(text) {
        var t = String(text || '').trim();
        return t.length > 90 ? t.slice(0, 87) + '…' : t;
    }

    function qbRefocus(index) {
        setTimeout(function () {
            var rows = $$('#qb-tbody .qb-row');
            var row = rows[Math.min(index, rows.length - 1)];
            var target = row || $('#qb-add-btn');
            if (target) {
                target.focus({ preventScroll: true });
            }
        }, 220);
    }

    async function qbDeleteOne(id, btn) {
        var list = Admin.qb.bank[Admin.qb.topic];
        var index = list.findIndex(function (q) {
            return q.id === id;
        });
        if (index === -1) {
            return;
        }
        var item = list[index];

        var ok = await Admin.confirmAction({
            heading: 'Delete question ' + (index + 1) + '?',
            message:
                '“' + qbShort(item.q) + '” and its steps and hints will be removed. This cannot be undone.',
            confirmLabel: 'Delete question'
        });
        if (!ok) {
            return;
        }

        var release = Admin.setBusy(btn, '…');
        var res = await sb.from('question_bank').delete().eq('id', id);
        release();

        if (res.error) {
            Admin.toastErr(
                'Question not deleted',
                Admin.friendlyDbError(res.error, 'Delete rejected.')
            );
            return;
        }

        Admin.qb.bank[Admin.qb.topic] = Admin.qb.bank[Admin.qb.topic].filter(function (q) {
            return q.id !== id;
        });
        Admin.renderQbTable();
        Admin.renderQbChrome();
        Admin.toastOk(
            'Question deleted',
            Admin.qbTopicLabel(Admin.qb.topic) +
                ' now has ' +
                Admin.qb.bank[Admin.qb.topic].length +
                '.'
        );
        qbRefocus(index);
    }
    Admin.qbDeleteOne = qbDeleteOne;

    async function qbDeleteAll() {
        var topic = Admin.qb.topic;
        var count = Admin.qb.bank[topic].length;
        if (!count || Admin.qb.busy.bulk) {
            return;
        }

        var ok = await Admin.confirmAction({
            heading: 'Delete all ' + count + ' questions in topic ' + Admin.QB_TOPICS[topic].num + '?',
            message: 'Their steps and hints are removed too. The other topics are not touched. This cannot be undone.',
            confirmLabel: 'Delete all'
        });
        if (!ok) {
            return;
        }

        Admin.qb.busy.bulk = true;
        var release = function () {};
        var res = await sb.from('question_bank').delete().eq('difficulty', topic);
        release();
        Admin.qb.busy.bulk = false;

        if (res.error) {
            Admin.renderQbToolbar();
            Admin.toastErr(
                'Questions not deleted',
                Admin.friendlyDbError(res.error, 'Delete rejected.')
            );
            return;
        }

        Admin.qb.bank[topic] = [];
        Admin.renderQbAll();
        Admin.toastOk(
            'Topic cleared',
            count + ' questions removed from ' + Admin.qbTopicLabel(topic) + '.'
        );
        setTimeout(function () {
            $('#qb-add-btn').focus({ preventScroll: true });
        }, 220);
    }
    Admin.qbDeleteAll = qbDeleteAll;

    function qbStepList() {
        return $('#qb-steps');
    }
    Admin.qbStepList = qbStepList;

    function qbAddStep(data, focus) {
        var node = $('#tpl-qb-step').content.firstElementChild.cloneNode(true);
        var seq = ++Admin.qb.stepSeq;
        var step = Admin.qbCleanStep(data);

        $$('[data-step]', node).forEach(function (input) {
            var key = input.getAttribute('data-step');
            input.id = 'qb-step-' + seq + '-' + key;
            input.value = step[key] || '';
        });
        $$('label[data-for]', node).forEach(function (label) {
            label.htmlFor = 'qb-step-' + seq + '-' + label.getAttribute('data-for');
        });

        qbStepList().appendChild(node);
        qbRenumberSteps();
        if (focus) {
            $('[data-step="prompt"]', node).focus();
        }
    }

    function qbRenumberSteps() {
        var steps = $$('.qb-step', qbStepList());
        steps.forEach(function (li, i) {
            $('.qb-step-title', li).textContent =
                'Step ' + (i + 1) + ' · ' + Admin.QB_STEP_LABELS[Admin.qb.topic][i];
        });
    }

    var QB_RESULT_PATTERN =
        /((?:=|\b(?:answers?|results?|equals?|gives?|gets?)\b)\s*(?:is|are|:|=)?\s*)(-?\d[\d,]*(?:\.\d+)?)(\s*%?)/gi;

    function qbNumberOf(text) {
        var m = String(text == null ? '' : text)
            .replace(/,/g, '')
            .match(/-?\d+(?:\.\d+)?/);
        return m ? Number(m[0]) : null;
    }

    function qbHintGivesAnswer(hint, answers) {
        var nums = answers.map(qbNumberOf).filter(function (n) {
            return n !== null;
        });
        var leaks = false;
        String(hint || '').replace(QB_RESULT_PATTERN, function (full, lead, num) {
            var v = Number(String(num).replace(/,/g, ''));
            if (
                nums.some(function (n) {
                    return Math.abs(n - v) < 1e-9;
                })
            ) {
                leaks = true;
            }
            return full;
        });
        return leaks;
    }

    function qbReadSteps() {
        return $$('.qb-step', qbStepList()).map(function (li) {
            var s = {};
            ['prompt', 'answer', 'hint1', 'hint2', 'hint3'].forEach(function (key) {
                s[key] = $('[data-step="' + key + '"]', li).value.trim();
            });
            return s;
        });
    }

    // Add and Edit question run as a wizard: Problem, one page per required step, then Review.
    // Edit shows the whole form at once.
    var wiz = { on: false, stage: 0 };

    function wizLast() {
        return $$('.qb-step', qbStepList()).length + 1;
    }

    function wizLabels() {
        var out = ['Problem'];
        $$('.qb-step', qbStepList()).forEach(function (_, i) {
            out.push('Step ' + (i + 1));
        });
        out.push('Review');
        return out;
    }

    function wizReview() {
        var steps = qbReadSteps();
        var box = $('#qb-review');
        var rows =
            '<p class="form-section-title">Review</p>' +
            reviewRow('Problem', $('#qb-question').value.trim(), 0) +
            reviewRow(
                'Final answer · points',
                ($('#qb-final').value.trim() || (steps.length && steps[steps.length - 1].answer) || '—') +
                    ' · ' +
                    ($('#qb-points').value || '—') +
                    ' pts',
                0
            );
        steps.forEach(function (st, i) {
            var hints = ['hint1', 'hint2', 'hint3'].filter(function (k) {
                return st[k];
            }).length;
            rows += reviewRow(
                'Step ' + (i + 1) + ' · ' + Admin.QB_STEP_LABELS[Admin.qb.topic][i],
                (st.prompt || '—') + ' → ' + (st.answer || '—') + ' · ' + hints + ' hint' + (hints === 1 ? '' : 's'),
                i + 1
            );
        });
        box.innerHTML = rows;
    }

    function reviewRow(label, value, stage) {
        return (
            '<div class="qb-review-row"><div><span class="qb-review-label">' +
            Admin.esc(label) +
            '</span><p>' +
            Admin.esc(value) +
            '</p></div><button type="button" class="btn btn-ghost btn-sm" data-wiz-go="' +
            stage +
            '">Edit</button></div>'
        );
    }

    function wizPaint() {
        var on = wiz.on;
        var last = wizLast();
        var review = on && wiz.stage === last;
        $('#qb-wiz').hidden = !on;
        $('#qb-problem-section').hidden = on && wiz.stage !== 0;
        $('#qb-steps-section').hidden = on && (wiz.stage === 0 || review);
        $('#qb-review').hidden = !review;
        $$('.qb-step', qbStepList()).forEach(function (li, i) {
            li.hidden = on && wiz.stage !== i + 1;
        });
        $('#qb-wiz-back').hidden = !on || wiz.stage === 0;
        $('#qb-wiz-next').hidden = !on || review;
        $('#qb-edit-save').hidden = on && !review;
        if (on) {
            $('#qb-wiz').innerHTML = wizLabels()
                .map(function (label, i) {
                    return (
                        '<li class="' +
                        (i === wiz.stage ? 'is-current' : i < wiz.stage ? 'is-done' : '') +
                        '"' +
                        (Admin.qb.editingId != null ? ' data-wiz-go="' + i + '" tabindex="0" role="button"' : '') +
                        (i === wiz.stage ? ' aria-current="step"' : '') +
                        '><span>' +
                        (i + 1) +
                        '</span> ' +
                        label +
                        '</li>'
                    );
                })
                .join('');
            if (review) {
                wizReview();
            }
        }
    }

    // checks only the page you are on; returns true when it may move on
    function wizCheck() {
        Admin.clearFormErrors('qb-edit-form');
        $('#qb-step-error').textContent = '';
        $$('#qb-edit-form [aria-invalid]').forEach(function (el) {
            el.removeAttribute('aria-invalid');
        });
        if (wiz.stage === 0) {
            var okQ = Admin.setFieldError(
                'qb-question',
                $('#qb-question').value.trim() ? '' : 'Write the sentence problem.'
            );
            var okP = Admin.setFieldError(
                'qb-points',
                Admin.qbPoints($('#qb-points').value) === null
                    ? 'Use a whole number from 1 to ' + Admin.QB_POINTS_MAX + '.'
                    : ''
            );
            if (!okQ) {
                $('#qb-question').focus();
            } else if (!okP) {
                $('#qb-points').focus();
            }
            return okQ && okP;
        }
        var steps = qbReadSteps();
        var i = wiz.stage - 1;
        var li = $$('.qb-step', qbStepList())[i];
        var st = steps[i];
        if (!st.prompt || !st.answer) {
            $('#qb-step-error').textContent = 'Enter a prompt and answer for this step.';
            var f = $('[data-step="' + (!st.prompt ? 'prompt' : 'answer') + '"]', li);
            f.setAttribute('aria-invalid', 'true');
            f.focus();
            return false;
        }
        var finalForCheck = $('#qb-final').value.trim() || st.answer;
        for (var hk = 1; hk <= 3; hk++) {
            if (qbHintGivesAnswer(st['hint' + hk], [st.answer, finalForCheck])) {
                var h = $('[data-step="hint' + hk + '"]', li);
                h.setAttribute('aria-invalid', 'true');
                $('#qb-step-error').textContent =
                    'Hint ' +
                    hk +
                    ' gives the answer away. A hint should guide the student, for example "Subtract 900 from 1200", not show the result.';
                h.focus();
                return false;
            }
        }
        return true;
    }

    function wizGo(stage) {
        wiz.stage = Math.max(0, Math.min(wizLast(), stage));
        wizPaint();
        var body = $('#qb-pane-write');
        if (body) {
            body.scrollTop = 0;
        }
    }

    function wizNext() {
        if (wizCheck()) {
            wizGo(wiz.stage + 1);
        }
    }

    function wizStart(on) {
        wiz.on = on;
        wiz.stage = 0;
        wizPaint();
    }
    Admin.qbWizard = { start: wizStart, next: wizNext, go: wizGo, paint: wizPaint, state: wiz };

    function qbOpenEditor(id, trigger) {
        var item =
            id == null
                ? null
                : Admin.qb.bank[Admin.qb.topic].find(function (q) {
                      return q.id === id;
                  });
        if (id != null && !item) {
            return;
        }

        Admin.qb.editingId = item ? item.id : null;
        Admin.clearFormErrors('qb-edit-form');

        var index = item ? Admin.qb.bank[Admin.qb.topic].indexOf(item) + 1 : 0;
        $('#qb-edit-title').textContent = item ? 'Edit question ' + index : 'Add question';
        $('#qb-edit-sub').textContent = Admin.qbTopicLabel(Admin.qb.topic);
        $('#qb-edit-save').textContent = item ? 'Save changes' : 'Add question';
        $('#qb-edit-delete').hidden = !item;
        $('#qb-step-count').textContent =
            Admin.QB_STEP_LABELS[Admin.qb.topic].length + ' required steps';
        $('#qb-step-error').textContent =
            item && item.steps.length > Admin.QB_STEP_LABELS[Admin.qb.topic].length
                ? 'This older question has extra steps. Only the required steps will be kept when you save.'
                : '';

        var uniform = Admin.qbUniformPoints(Admin.qb.bank[Admin.qb.topic]);
        var stash = !item && Admin.qb.stash && Admin.qb.stash.topic === Admin.qb.topic ? Admin.qb.stash : null;
        $('#qb-question').value = item ? item.q : stash ? stash.question : '';
        $('#qb-final').value = item ? item.final : stash ? stash.final : '';
        $('#qb-points').value = String(item ? item.points : stash ? stash.points : uniform || 10);

        qbStepList().textContent = '';
        var steps = Admin.QB_STEP_LABELS[Admin.qb.topic].map(function (_, i) {
            return (item && item.steps[i]) || (stash && stash.steps[i]) || null;
        });
        steps.forEach(function (s) {
            qbAddStep(s, false);
        });

        Admin.qb.editSnap = qbSnap();
        $('#qb-mode').hidden = !!item;
        wizStart(true);
        Admin.qb.drafts = stash ? JSON.parse(JSON.stringify(stash.drafts)) : [];
        qbSetMode(stash && stash.mode === 'gen' ? 'gen' : 'write');
        if (stash) {
            Admin.toastOk('Draft restored', 'Your unsaved question is back.');
        }
        $('#qb-edit-title').textContent = item ? 'Edit question ' + index : 'Add question';
        Admin.openModal('modal-qb-edit', trigger);

        $('#qb-question').focus({ preventScroll: true });
        $('#modal-qb-edit .modal-body').scrollTop = 0;
    }
    Admin.qbOpenEditor = qbOpenEditor;

    // closing Add question with something typed or generated asks: save a draft or discard
    function qbSnap() {
        return JSON.stringify([
            $('#qb-question').value,
            $('#qb-final').value,
            $('#qb-points').value,
            qbReadSteps()
        ]);
    }

    function qbDirty() {
        if (Admin.qb.editingId != null) {
            return qbSnap() !== Admin.qb.editSnap;
        }
        var typed =
            $('#qb-question').value.trim() ||
            $('#qb-final').value.trim() ||
            qbReadSteps().some(function (st) {
                return Object.keys(st).some(function (k) {
                    return st[k];
                });
            });
        return !!typed || Admin.qb.drafts.length > 0;
    }

    function qbDraftPrompt() {
        var ask = $('#modal-qb-draft');
        if (!ask) {
            ask = document.createElement('div');
            ask.className = 'overlay';
            ask.id = 'modal-qb-draft';
            ask.setAttribute('role', 'dialog');
            ask.setAttribute('aria-modal', 'true');
            ask.setAttribute('aria-labelledby', 'qb-draft-title');
            ask.innerHTML =
                '<div class="modal modal-sm">' +
                '<header class="modal-head"><div class="modal-head-text"><h2 class="modal-title" id="qb-draft-title">Save as draft?</h2></div></header>' +
                '<div class="modal-body"><p class="draft-text">This question is not saved yet. Keep it for later, or throw it away.</p></div>' +
                '<footer class="modal-foot">' +
                '<button type="button" class="btn btn-secondary" id="qb-draft-discard">Discard</button>' +
                '<button type="button" class="btn btn-primary" id="qb-draft-save">Save draft</button>' +
                '</footer></div>';
            document.body.appendChild(ask);
            ask.addEventListener('mousedown', function (event) {
                if (event.target === ask) {
                    Admin.closeModal(ask);
                }
            });
            $('#qb-draft-save', ask).addEventListener('click', function () {
                Admin.qb.stash = {
                    topic: Admin.qb.topic,
                    question: $('#qb-question').value,
                    final: $('#qb-final').value,
                    points: $('#qb-points').value,
                    steps: qbReadSteps(),
                    drafts: JSON.parse(JSON.stringify(Admin.qb.drafts)),
                    mode: $('#qb-pane-gen').hidden ? 'write' : 'gen'
                };
                Admin.closeModal(ask);
                Admin.closeModal('modal-qb-edit');
            });
            $('#qb-draft-discard', ask).addEventListener('click', function () {
                Admin.qb.stash = null;
                Admin.closeModal(ask);
                Admin.closeModal('modal-qb-edit');
            });
        }
        Admin.openModal('modal-qb-draft');
    }

    function qbGuardClose() {
        var overlay = $('#modal-qb-edit');
        function guard(event) {
            if (!qbDirty()) {
                return;
            }
            event.stopImmediatePropagation();
            event.preventDefault();
            if (Admin.qb.editingId != null) {
                Admin.confirmAction({
                    heading: 'Discard changes?',
                    message: 'Your edits to this question are not saved.',
                    confirmLabel: 'Discard'
                }).then(function (ok) {
                    if (ok) {
                        Admin.closeModal('modal-qb-edit');
                    }
                });
                return;
            }
            qbDraftPrompt();
        }
        overlay.addEventListener(
            'click',
            function (event) {
                if (event.target.closest('[data-modal-close]')) {
                    guard(event);
                }
            },
            true
        );
        overlay.addEventListener(
            'mousedown',
            function (event) {
                if (event.target === overlay) {
                    guard(event);
                }
            },
            true
        );
        document.addEventListener(
            'keydown',
            function (event) {
                var layers = Admin.openLayers;
                if (event.key === 'Escape' && layers[layers.length - 1] === overlay) {
                    guard(event);
                }
            },
            true
        );
    }
    qbGuardClose();


    async function qbSaveEditor(event) {
        event.preventDefault();
        if (wiz.on && wiz.stage < wizLast()) {
            wizNext();
            return;
        }
        if (Admin.qb.busy.edit) {
            return;
        }
        Admin.clearFormErrors('qb-edit-form');

        var question = $('#qb-question').value.trim();
        var finalAnswer = $('#qb-final').value.trim();
        var points = Admin.qbPoints($('#qb-points').value);
        var steps = qbReadSteps();

        var valid = true;
        valid =
            Admin.setFieldError('qb-question', question ? '' : 'Write the sentence problem.') &&
            valid;
        valid =
            Admin.setFieldError(
                'qb-points',
                points === null ? 'Use a whole number from 1 to ' + Admin.QB_POINTS_MAX + '.' : ''
            ) && valid;
        var badStep = steps.findIndex(function (step) {
            return !step.prompt || !step.answer;
        });
        if (badStep !== -1) {
            $('#qb-step-error').textContent = 'Enter a prompt and answer for every required step.';
            var fields = $$('.qb-step', qbStepList());
            var target = $(
                '[data-step="' + (!steps[badStep].prompt ? 'prompt' : 'answer') + '"]',
                fields[badStep]
            );
            target.setAttribute('aria-invalid', 'true');
            if (valid) {
                target.focus();
            }
            valid = false;
        } else {
            $('#qb-step-error').textContent = '';
        }
        if (valid) {
            var finalForCheck = finalAnswer || steps[steps.length - 1].answer;
            var stepFields = $$('.qb-step', qbStepList());
            outer: for (var si = 0; si < steps.length; si++) {
                for (var hk = 1; hk <= 3; hk++) {
                    if (
                        qbHintGivesAnswer(steps[si]['hint' + hk], [steps[si].answer, finalForCheck])
                    ) {
                        var hintField = $('[data-step="hint' + hk + '"]', stepFields[si]);
                        hintField.setAttribute('aria-invalid', 'true');
                        $('#qb-step-error').textContent =
                            'Step ' +
                            (si + 1) +
                            ', Hint ' +
                            hk +
                            ' gives the answer away. A hint should guide the student, for example "Subtract 900 from 1200", not show the result.';
                        hintField.focus();
                        valid = false;
                        break outer;
                    }
                }
            }
        }
        if (!valid) {
            var bad = $('#qb-edit-form .is-invalid');
            if (bad) {
                bad.focus();
            }
            return;
        }
        if (!finalAnswer) {
            finalAnswer = steps[steps.length - 1].answer;
        }

        var current =
            Admin.qb.editingId == null
                ? null
                : Admin.qb.bank[Admin.qb.topic].find(function (q) {
                      return q.id === Admin.qb.editingId;
                  });
        var payload = {
            question: question,
            final_answer: finalAnswer,
            hint: Admin.qbSerializeHint(steps, current ? current.hint : ''),
            points: points
        };

        Admin.qb.busy.edit = true;
        var release = Admin.setBusy($('#qb-edit-save'), 'Saving…');
        var editing = Admin.qb.editingId;
        var topic = Admin.qb.topic;
        var res =
            editing != null
                ? await sb
                      .from('question_bank')
                      .update(payload)
                      .eq('id', editing)
                      .select(Admin.QB_COLUMNS)
                      .maybeSingle()
                : await sb
                      .from('question_bank')
                      .insert([Object.assign({ difficulty: topic }, payload)])
                      .select(Admin.QB_COLUMNS)
                      .single();
        release();
        Admin.qb.busy.edit = false;

        if (res.error || !res.data) {
            Admin.toastErr(
                editing != null ? 'Changes not saved' : 'Question not added',
                Admin.friendlyDbError(
                    res.error,
                    'This question may have been deleted elsewhere. Reload the page to check.'
                )
            );
            return;
        }

        var saved = Admin.qbFromRow(res.data);
        var list = Admin.qb.bank[topic];
        if (editing != null) {
            var at = list.findIndex(function (q) {
                return q.id === editing;
            });
            if (at !== -1) {
                list[at] = saved;
            } else {
                list.push(saved);
            }
        } else {
            list.push(saved);
        }

        if (editing == null) {
            Admin.qb.stash = null;
        }
        Admin.closeModal('modal-qb-edit');
        Admin.renderQbTable();
        Admin.renderQbChrome();

        if (editing != null) {
            setTimeout(function () {
                var row = qbRowEl(editing);
                var btn = row;
                if (btn) {
                    btn.focus({ preventScroll: true });
                }
            }, 220);
        }
        Admin.toastOk(
            editing != null ? 'Question updated' : 'Question added',
            Admin.qbTopicLabel(topic) +
                ' · ' +
                (steps.length ? Admin.qbStepSummary(saved) : 'no steps')
        );
    }
    Admin.qbSaveEditor = qbSaveEditor;

    // the Add question dialog has two modes: write one question, or auto-generate several
    function qbSetMode(mode) {
        var gen = mode === 'gen';
        $('#qb-pane-write').hidden = gen;
        $('#qb-foot-write').hidden = gen;
        $('#qb-pane-gen').hidden = !gen;
        $('#qb-foot-gen').hidden = !gen;
        $$('#qb-mode [data-qb-mode]').forEach(function (btn) {
            var on = btn.getAttribute('data-qb-mode') === mode;
            btn.classList.toggle('is-active', on);
            btn.setAttribute('aria-pressed', on ? 'true' : 'false');
        });
        if (gen) {
            $('#qb-edit-title').textContent = 'Auto-generate questions';
            $('#qb-gen-status').textContent = '';
            $('#qb-gen-run').className = 'btn btn-secondary';
            $('#qb-gen-run').disabled = true;
            $('#qb-gen-count').value = '';
            qbPaintRanges();
            renderQbDrafts();
            $('#qb-gen-count').focus({ preventScroll: true });
        } else {
            $('#qb-edit-title').textContent = Admin.qb.editingId == null ? 'Add question' : $('#qb-edit-title').textContent;
            wizPaint();
            $('#qb-question').focus({ preventScroll: true });
        }
    }
    Admin.qbSetMode = qbSetMode;


    function renderQbDrafts() {
        var list = $('#qb-previews');
        list.textContent = '';

        Admin.qb.drafts.forEach(function (draft, i) {
            var node = $('#tpl-qb-preview').content.firstElementChild.cloneNode(true);
            node.setAttribute('data-index', String(i));
            $('.qb-preview-num', node).textContent = String(i + 1);
            $('[data-qb-remove-preview]', node).setAttribute(
                'aria-label',
                'Remove draft ' + (i + 1)
            );

            $$('[data-preview]', node).forEach(function (input) {
                var key = input.getAttribute('data-preview');
                input.id = 'qb-draft-' + i + '-' + key;
                input.value = String(draft[key] == null ? '' : draft[key]);
            });
            $$('label[data-for]', node).forEach(function (label) {
                label.htmlFor = 'qb-draft-' + i + '-' + label.getAttribute('data-for');
            });
            $('.qb-preview-meta', node).textContent =
                (draft.range && window.PIAMathGen.RANGES[draft.range]
                    ? window.PIAMathGen.RANGES[draft.range].label + ' · '
                    : '') +
                Admin.qbStepSummary(draft) +
                ' included — edit them after saving.';
            list.appendChild(node);
        });

        var n = Admin.qb.drafts.length;
        $('#qb-gen-empty').classList.toggle('is-hidden', n > 0);
        var save = $('#qb-gen-save');
        save.disabled = n === 0 || Admin.qb.busy.drafts;
        save.textContent = n ? 'Save ' + n + ' to bank' : 'Save to bank';
    }
    Admin.renderQbDrafts = renderQbDrafts;

    var QB_RANGE_BOXES = {
        tens: '#qb-gen-tens',
        hundreds: '#qb-gen-hundreds',
        thousands: '#qb-gen-thousands'
    };

    function qbPaintRanges() {
        Object.keys(QB_RANGE_BOXES).forEach(function (r) {
            $(QB_RANGE_BOXES[r]).checked = Admin.qb.genRanges.indexOf(r) !== -1;
        });
        $('#qb-gen-range-msg').textContent = '';
        $('#qb-gen-range').classList.remove('is-invalid');
    }

    function qbReadRanges() {
        return Object.keys(QB_RANGE_BOXES).filter(function (r) {
            return $(QB_RANGE_BOXES[r]).checked;
        });
    }

    function qbGenerateDrafts(event) {
        event.preventDefault();
        var ranges = qbReadRanges();
        Admin.qb.genRanges = ranges;
        if (!ranges.length) {
            $('#qb-gen-range-msg').textContent = 'Select at least one number range.';
            $('#qb-gen-range').classList.add('is-invalid');
            $('#qb-gen-status').textContent = 'Select at least one number range.';
            $('#qb-gen-tens').focus();
            return;
        }
        $('#qb-gen-range-msg').textContent = '';
        $('#qb-gen-range').classList.remove('is-invalid');
        var count = Math.max(1, Math.min(50, Admin.toInt($('#qb-gen-count').value, 5)));
        var pts = Admin.qbUniformPoints(Admin.qb.bank[Admin.qb.topic]) || 10;
        Admin.qb.drafts = window.PIAMathGen.generateBatch(Admin.qb.topic, pts, count, ranges);
        renderQbDrafts();
        $('#qb-gen-status').textContent =
            count + (count === 1 ? ' draft' : ' drafts') + ' ready to review.';
    }
    Admin.qbGenerateDrafts = qbGenerateDrafts;

    async function qbSaveDrafts() {
        if (Admin.qb.busy.drafts || !Admin.qb.drafts.length) {
            return;
        }

        for (var i = 0; i < Admin.qb.drafts.length; i++) {
            var d = Admin.qb.drafts[i];
            var pts = Admin.qbPoints(d.points);
            var validSteps =
                d.steps.length === Admin.QB_STEP_LABELS[Admin.qb.topic].length &&
                d.steps.every(function (s) {
                    return String(s.prompt || '').trim() && String(s.answer || '').trim();
                });
            if (!String(d.q || '').trim() || pts === null || !validSteps) {
                if (!validSteps) {
                    Admin.toastErr(
                        'Draft ' + (i + 1) + ' needs a fix',
                        'Every required step needs a prompt and answer.'
                    );
                    return;
                }
                var field = !String(d.q || '').trim() ? 'q' : 'points';
                var input = document.getElementById('qb-draft-' + i + '-' + field);
                if (input) {
                    input.focus();
                }
                Admin.toastErr(
                    'Draft ' + (i + 1) + ' needs a fix',
                    field === 'q'
                        ? 'The problem statement is empty.'
                        : 'Points must be a whole number from 1 to ' + Admin.QB_POINTS_MAX + '.'
                );
                return;
            }
        }

        var topic = Admin.qb.topic;
        var rows = Admin.qb.drafts.map(function (d) {
            return {
                difficulty: topic,
                question: String(d.q).trim(),
                final_answer: String(d.final || '').trim(),
                hint: Admin.qbSerializeHint(d.steps.map(Admin.qbCleanStep)),
                points: Admin.qbPoints(d.points)
            };
        });

        Admin.qb.busy.drafts = true;
        var release = Admin.setBusy($('#qb-gen-save'), 'Saving…');
        var res = await sb.from('question_bank').insert(rows).select(Admin.QB_COLUMNS);
        release();
        Admin.qb.busy.drafts = false;

        if (res.error || !res.data) {
            renderQbDrafts();
            Admin.toastErr(
                'Drafts not saved',
                Admin.friendlyDbError(res.error, 'Insert rejected.')
            );
            return;
        }

        res.data.forEach(function (row) {
            Admin.qb.bank[topic].push(Admin.qbFromRow(row));
        });
        Admin.qb.drafts = [];
        Admin.qb.stash = null;
        Admin.closeModal('modal-qb-edit');
        Admin.renderQbTable();
        Admin.renderQbChrome();
        Admin.toastOk(
            res.data.length + (res.data.length === 1 ? ' question saved' : ' questions saved'),
            Admin.qbTopicLabel(topic)
        );
    }
    Admin.qbSaveDrafts = qbSaveDrafts;
})();
