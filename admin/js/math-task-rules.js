/*
 * Math task bank (3 of 3).
 * Saving the rules and wiring the math task page.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    // "dirty" = what is on the screen differs from what is saved; Save stays off until it does
    function qbMarkDirty() {
        Admin.qb.dirty =
            Admin.qbConfigSig(Admin.qb.closesAt, Admin.qb.rules, null) !== Admin.qb.configSeen;
        $('#qb-config-save').disabled =
            Admin.qb.status !== 'ready' || Admin.qb.busy.config || !Admin.qb.dirty;
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
        Admin.QB_ORDER.forEach(function (topic) {
            var key = topic.toLowerCase();
            row[key + '_mastery'] = Admin.toInt(Admin.qb.rules[topic].mastery, 80);
            row[key + '_min_questions'] = Admin.toInt(Admin.qb.rules[topic].minQuestions, 3);
            row[key + '_max_errors'] = Admin.toInt(Admin.qb.rules[topic].maxErrors, 3);
        });

        var sure = await Admin.confirmAction({
            heading: 'Save the rules?',
            message:
                'They apply to every section.',
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
        Admin.qb.configSeen = Admin.qbConfigSig(
            Admin.qb.closesAt,
            Admin.qb.rules,
            null
        );
        Admin.renderQbRules();
        Admin.closeModal('modal-qb-rules');
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
            if (event.target.closest('[data-topic-delete]')) {
                closeTopicMenu();
                Admin.qbDeleteAll();
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

        function qbGoPage(step) {
            Admin.qb.page = (Admin.qb.page || 1) + step;
            Admin.renderQbTable();
        }
        $('#qb-page-prev').addEventListener('click', function () {
            qbGoPage(-1);
        });
        $('#qb-page-next').addEventListener('click', function () {
            qbGoPage(1);
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
        // what is saved is what the window shows when it opens (if the server has not told us yet)
        $('#qb-rules-btn').addEventListener('click', function () {
            if (Admin.qb.configSeen === null || Admin.qb.configSeen === undefined) {
                Admin.qb.configSeen = Admin.qbConfigSig(Admin.qb.closesAt, Admin.qb.rules, null);
            }
        });
        // Cancel closes the window; unsaved edits are thrown away after asking
        $('#qb-config-cancel').addEventListener('click', async function () {
            if (Admin.qb.dirty) {
                var answer = await Admin.askUnsaved();
                if (!answer) {
                    return;
                }
                // Save draft keeps the edits on the screen's state (they are back when Rules is opened again)
                if (answer === 'discard') {
                    Admin.qb.dirty = false;
                    await Admin.loadMathTask();
                }
            }
            Admin.closeModal('modal-qb-rules');
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
