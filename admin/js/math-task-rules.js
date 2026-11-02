/*
 * Math task bank (3 of 3).
 * Saving the rules and wiring the math task page.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function qbMarkDirty() {
        Admin.qb.dirty = true;
        $('#qb-dirty').classList.add('is-on');
    }

    async function qbSaveRules(event) {
        event.preventDefault();
        if (Admin.qb.busy.config || Admin.qb.status !== 'ready') {
            return;
        }
        Admin.clearFormErrors('qb-config-form');

        var fields = [
            ['minQuestions', 'qb-min-questions', 'Solved to level up'],
            ['maxErrors', 'qb-max-errors', 'Wrong to level down']
        ];
        var order = [Admin.qb.topic].concat(
            Admin.QB_ORDER.filter(function (t) {
                return t !== Admin.qb.topic;
            })
        );

        for (var i = 0; i < order.length; i++) {
            for (var j = 0; j < fields.length; j++) {
                var value = Admin.qb.rules[order[i]][fields[j][0]];
                if (Admin.qbIntIn(value, 1, 10) === null) {
                    if (order[i] !== Admin.qb.topic) {
                        Admin.qbSwitchTopic(order[i]);
                    }
                    Admin.setFieldError(fields[j][1], 'Use a whole number from 1 to 10.');
                    $('#' + fields[j][1]).focus();
                    return;
                }
            }
        }

        var row = { id: 1 };
        if (Admin.qb.hasScoring) {
            var scv = Admin.qb.scoring,
                specs = [
                    ['qb-sc-wrong', scv.wrong, 0, 100, 'a whole number from 0 to 100'],
                    ['qb-sc-hint', scv.hint, 0, 100, 'a whole number from 0 to 100'],
                    ['qb-sc-fast', scv.fast, 0, 100, 'a whole number from 0 to 100'],
                    ['qb-sc-secs', scv.secs, 1, 3600, 'a whole number of seconds from 1 to 3600'],
                    ['qb-sc-min', scv.min, 0, 500, 'a whole number from 0 to 500'],
                    ['qb-sc-repeat-pct', scv.repeatPct, 0, 100, 'a whole number from 0 to 100']
                ],
                values = {};
            for (var spi = 0; spi < specs.length; spi++) {
                var sv = Admin.qbWhole(specs[spi][1], specs[spi][2], specs[spi][3]);
                if (sv === null) {
                    Admin.setFieldError(specs[spi][0], 'Use ' + specs[spi][4] + '.');
                    $('#' + specs[spi][0]).focus();
                    return;
                }
                values[specs[spi][0]] = sv;
            }
            row.score_wrong_pct = values['qb-sc-wrong'];
            row.score_hint_pct = values['qb-sc-hint'];
            row.score_fast_bonus_pct = values['qb-sc-fast'];
            row.score_fast_seconds = values['qb-sc-secs'];
            row.score_min = values['qb-sc-min'];
            row.score_repeat_pct = values['qb-sc-repeat-pct'];
            row.score_speed_bonus = !!scv.speed;
            row.score_repeat_enabled = !!scv.repeatOn;
        }
        Admin.QB_ORDER.forEach(function (topic) {
            var key = topic.toLowerCase();
            row[key + '_mastery'] = Admin.toInt(Admin.qb.rules[topic].mastery, 80);
            row[key + '_min_questions'] = Admin.toInt(Admin.qb.rules[topic].minQuestions, 3);
            row[key + '_max_errors'] = Admin.toInt(Admin.qb.rules[topic].maxErrors, 3);
        });

        var sure = await Admin.confirmAction({
            title: 'Save rules',
            heading: 'Apply these rules to every student?',
            message:
                'The new rules count for questions finished from now on, in every section. Scores already earned are not changed.',
            confirmLabel: 'Save rules',
            tone: 'accent'
        });
        if (!sure) {
            return;
        }

        Admin.qb.busy.config = true;
        var release = Admin.setBusy($('#qb-config-save'), 'Saving…');
        var res = await sb.from('app_config').upsert(row);
        release();
        Admin.qb.busy.config = false;

        if (res.error) {
            Admin.renderQbRules();
            Admin.toastErr('Rules not saved', Admin.friendlyDbError(res.error, 'Save rejected.'));
            return;
        }

        Admin.qb.dirty = false;
        if (Admin.qb.hasScoring) {
            Admin.qb.scoring = {
                wrong: row.score_wrong_pct,
                hint: row.score_hint_pct,
                fast: row.score_fast_bonus_pct,
                secs: row.score_fast_seconds,
                speed: row.score_speed_bonus,
                min: row.score_min,
                repeatOn: row.score_repeat_enabled,
                repeatPct: row.score_repeat_pct
            };
        }
        Admin.qb.configSeen = Admin.qbConfigSig(
            Admin.qb.closesAt,
            Admin.qb.rules,
            Admin.qb.hasScoring ? Admin.qb.scoring : null
        );
        Admin.renderQbRules();
        Admin.toastOk('Rules saved', 'All three topics updated.');
    }

    function initMathTask() {
        var topicHost = $('#qb-topic-host');
        function closeTopicMenu() {
            var m = topicHost.querySelector('[data-topic-menu]');
            var t = topicHost.querySelector('[data-topic-toggle]');
            if (m) {
                m.hidden = true;
            }
            if (t) {
                t.setAttribute('aria-expanded', 'false');
            }
        }
        topicHost.addEventListener('click', function (event) {
            var pick = event.target.closest('[data-topic-pick]');
            if (pick) {
                closeTopicMenu();
                Admin.qbSwitchTopic(pick.getAttribute('data-topic-pick'));
                return;
            }
            if (event.target.closest('[data-topic-toggle]')) {
                var m = topicHost.querySelector('[data-topic-menu]');
                m.hidden = !m.hidden;
                topicHost
                    .querySelector('[data-topic-toggle]')
                    .setAttribute('aria-expanded', String(!m.hidden));
            }
        });
        document.addEventListener('click', function (event) {
            if (!topicHost.contains(event.target)) {
                closeTopicMenu();
            }
        });
        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape') {
                closeTopicMenu();
            }
        });

        // unsaved rules are lost on reload, so the browser asks first
        window.addEventListener('beforeunload', function (event) {
            if (Admin.qb.dirty) {
                event.preventDefault();
                event.returnValue = '';
            }
        });

        $$('[data-qb-topic]').forEach(function (btn) {
            btn.addEventListener('click', function () {
                Admin.qbSwitchTopic(btn.getAttribute('data-qb-topic'));
            });
        });

        var tbody = $('#qb-tbody');
        function rowId(row) {
            return Admin.toInt(row && row.getAttribute('data-id'), null);
        }
        tbody.addEventListener('click', function (event) {
            var row = event.target.closest('.qb-row');
            var id = rowId(row);
            if (id === null) {
                return;
            }
            if (!event.target.closest('button, a, input')) {
                Admin.qbOpenEditor(id, row);
            }
        });
        tbody.addEventListener('keydown', function (event) {
            var row = event.target.closest('.qb-row');
            if (row && event.target === row && (event.key === 'Enter' || event.key === ' ')) {
                event.preventDefault();
                var id = rowId(row);
                if (id !== null) {
                    Admin.qbOpenEditor(id, row);
                }
            }
        });
        tbody.addEventListener('focusout', function () {
            setTimeout(function () {
                if (Admin.qb.renderPending && !tbody.contains(document.activeElement)) {
                    Admin.renderQbTable();
                }
            }, 0);
        });

        $('#qb-edit-delete').addEventListener('click', function () {
            var id = Admin.qb.editingId;
            if (id == null) {
                return;
            }
            Admin.closeModal('modal-qb-edit');
            Admin.qbDeleteOne(id, this);
        });
        $('#qb-add-btn').addEventListener('click', function () {
            Admin.qbOpenEditor(null, this);
        });
        // typing a count turns Generate yellow
        $('#qb-gen-count').addEventListener('input', function () {
            var run = $('#qb-gen-run');
            var ok = Number(this.value) >= 1;
            run.classList.toggle('btn-primary', ok);
            run.classList.toggle('btn-secondary', !ok);
            run.disabled = !ok;
        });
        $('#qb-wiz-next').addEventListener('click', Admin.qbWizard.next);
        $('#qb-wiz-back').addEventListener('click', function () {
            Admin.qbWizard.go(Admin.qbWizard.state.stage - 1);
        });
        $('#qb-wiz').addEventListener('click', function (event) {
            var go = event.target.closest('[data-wiz-go]');
            if (go) {
                Admin.qbWizard.go(Number(go.getAttribute('data-wiz-go')));
            }
        });
        $('#qb-review').addEventListener('click', function (event) {
            var go = event.target.closest('[data-wiz-go]');
            if (go) {
                Admin.qbWizard.go(Number(go.getAttribute('data-wiz-go')));
            }
        });
        $$('#qb-mode [data-qb-mode]').forEach(function (btn) {
            btn.addEventListener('click', function () {
                Admin.qbSetMode(btn.getAttribute('data-qb-mode'));
            });
        });
        $('#qb-delete-all').addEventListener('click', Admin.qbDeleteAll);

        $('#qb-mastery').addEventListener('input', function () {
            Admin.qb.rules[Admin.qb.topic].mastery = Admin.toInt(this.value, 80);
            Admin.qbPaintRange();
            qbMarkDirty();
        });
        [
            ['#qb-min-questions', 'minQuestions'],
            ['#qb-max-errors', 'maxErrors']
        ].forEach(function (spec) {
            $(spec[0]).addEventListener('input', function () {
                Admin.qb.rules[Admin.qb.topic][spec[1]] = this.value;
                Admin.setFieldError(this.id, '');
                qbMarkDirty();
            });
        });
        [
            ['#qb-sc-wrong', 'wrong'],
            ['#qb-sc-hint', 'hint'],
            ['#qb-sc-fast', 'fast'],
            ['#qb-sc-secs', 'secs'],
            ['#qb-sc-min', 'min'],
            ['#qb-sc-repeat-pct', 'repeatPct']
        ].forEach(function (pair) {
            $(pair[0]).addEventListener('input', function () {
                Admin.qb.scoring[pair[1]] = this.value;
                Admin.setFieldError(this.id, '');
                qbMarkDirty();
                Admin.qbRenderScoringExample();
            });
        });
        [
            ['#qb-sc-speed', 'speed'],
            ['#qb-sc-repeat', 'repeatOn']
        ].forEach(function (pair) {
            $(pair[0]).addEventListener('change', function () {
                Admin.qb.scoring[pair[1]] = this.checked;
                qbMarkDirty();
                Admin.renderQbRules();
            });
        });

        // Rules opens from the questions card; Back to questions closes it
        function showQbView(view) {
            $('#qb-views').className = 'grid grid-main qb-view-' + view;
        }
        $('#qb-rules-btn').addEventListener('click', function () {
            showQbView('rules');
        });
        $('#qb-rules-back').addEventListener('click', function () {
            showQbView('questions');
        });
        $('#qb-config-form').addEventListener('submit', qbSaveRules);

        $('#qb-edit-form').addEventListener('submit', Admin.qbSaveEditor);
        Admin.qbStepList().addEventListener('input', function (event) {
            if (event.target.matches('[data-step]')) {
                event.target.removeAttribute('aria-invalid');
                $('#qb-step-error').textContent = '';
            }
        });
        ['qb-question', 'qb-points'].forEach(function (id) {
            $('#' + id).addEventListener('input', function () {
                Admin.setFieldError(id, '');
            });
        });

        $('#qb-gen-form').addEventListener('submit', Admin.qbGenerateDrafts);
        $('#qb-gen-save').addEventListener('click', Admin.qbSaveDrafts);
        var previews = $('#qb-previews');
        previews.addEventListener('input', function (event) {
            var input = event.target.closest('[data-preview]');
            var li = input && input.closest('.qb-preview');
            if (!li) {
                return;
            }
            var draft = Admin.qb.drafts[Admin.toInt(li.getAttribute('data-index'), -1)];
            if (draft) {
                draft[input.getAttribute('data-preview')] = input.value;
            }
        });
        previews.addEventListener('click', function (event) {
            var btn = event.target.closest('[data-qb-remove-preview]');
            if (!btn) {
                return;
            }
            var index = Admin.toInt(btn.closest('.qb-preview').getAttribute('data-index'), -1);
            if (index < 0) {
                return;
            }
            Admin.qb.drafts.splice(index, 1);
            Admin.renderQbDrafts();
            var rest = $$('[data-qb-remove-preview]', previews);
            (rest[Math.min(index, rest.length - 1)] || $('#qb-gen-run')).focus();
            $('#qb-gen-status').textContent = 'Draft removed. ' + Admin.qb.drafts.length + ' left.';
        });

        Admin.renderQbAll();
    }
    Admin.initMathTask = initMathTask;
})();
