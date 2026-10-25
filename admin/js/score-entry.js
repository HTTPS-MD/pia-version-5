/*
 * Score entry.
 * The window for typing the pre-test and post-test scores of a section.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function commonValue(values) {
        var counts = {};
        var best = null;
        values.forEach(function (v) {
            if (v == null) {
                return;
            }
            var key = String(v);
            counts[key] = (counts[key] || 0) + 1;
            if (best === null || counts[key] > counts[best]) {
                best = key;
            }
        });
        return best === null ? '' : best;
    }

    function scorePairCell(s, test) {
        var raw = s[test + '_test_raw_score'];
        var max = s[test + '_test_max_score'];
        var legacy =
            s[test + '_test_score'] != null && raw == null
                ? Admin.formatScore(s[test + '_test_score'])
                : '';
        var who = s.full_name || s.email;
        var label = test === 'pre' ? 'Pre-test' : 'Post-test';
        return (
            '' +
            '<td class="col-score" data-label="' +
            label +
            '">' +
            '<div class="score-pair" data-test="' +
            test +
            '" data-legacy="' +
            Admin.esc(legacy) +
            '"' +
            ' data-initial-raw="' +
            Admin.esc(raw == null ? '' : raw) +
            '" data-initial-max="' +
            Admin.esc(max == null ? '' : max) +
            '">' +
            '<input class="input score-input" type="number" step="any" min="0" inputmode="decimal" data-part="raw"' +
            ' aria-label="' +
            Admin.esc(label + ' raw score, ' + who) +
            '" value="' +
            Admin.esc(raw == null ? '' : raw) +
            '">' +
            '<span class="score-of tnum" aria-hidden="true">/ <span data-max-out>—</span></span>' +
            '<output class="score-out tnum"></output>' +
            '</div>' +
            '</td>'
        );
    }

    function sectionMax(test) {
        return $('#scores-max-' + test).value;
    }

    function paintScorePair(pair) {
        var test = pair.getAttribute('data-test');
        var out = pair.querySelector('.score-out');
        var maxText = sectionMax(test).trim();
        var read = Admin.readScorePair(
            pair.querySelector('[data-part="raw"]').value,
            maxText,
            true
        );
        var legacy = pair.getAttribute('data-legacy');

        pair.querySelector('[data-max-out]').textContent = maxText || '—';
        pair.classList.toggle('is-invalid', !read.ok);
        pair.querySelector('[data-part="raw"]').classList.toggle('is-invalid', !read.ok);
        out.classList.remove('is-legacy');
        out.removeAttribute('title');
        if (!read.ok) {
            out.textContent = read.error;
        } else if (read.score != null) {
            out.textContent = '= ' + Admin.formatScore(read.score);
        } else if (legacy) {
            out.textContent = legacy + ' · legacy';
            out.title = 'Entered before raw scores were kept. Type the raw score to replace it.';
            out.classList.add('is-legacy');
        } else {
            out.textContent = '—';
        }
    }
    Admin.paintScorePair = paintScorePair;

    async function openScoresModal(sectionName) {
        Admin.state.activeSection = sectionName;
        $('#scores-title').textContent = 'Input scores — ' + sectionName;
        $('#scores-tbody').innerHTML = Admin.skeletonRows(3, 5);
        $('#scores-max-pre').value = '';
        $('#scores-max-post').value = '';
        $('#scores-save').disabled = true;
        Admin.openModal('modal-scores');

        var res = await sb
            .from('profiles')
            .select(
                'role, full_name, email, group_type, pre_test_score, post_test_score' +
                    Admin.RAW_SCORE_COLUMNS
            )
            .eq('section', sectionName)
            .order('full_name', { ascending: true });

        if (res.error) {
            var missing = Admin.isMissingColumn(res.error);
            $('#scores-tbody').innerHTML =
                '<tr><td colspan="3">' +
                '<div class="state-block" style="min-height:200px">' +
                '<p class="state-title">' +
                (missing ? 'Raw scores are not set up yet' : 'Could not load scores') +
                '</p>' +
                '<p class="state-desc">' +
                Admin.esc(
                    missing
                        ? 'Score entry is not set up on this database yet. Ask whoever maintains the database to finish its setup, then reopen this dialog.'
                        : Admin.friendlyDbError(res.error, 'Unknown database error.')
                ) +
                '</p>' +
                '</div></td></tr>';
            return;
        }

        var students = (res.data || []).filter(function (row) {
            return (row.role || '').toLowerCase() !== 'admin';
        });

        if (!students.length) {
            $('#scores-tbody').innerHTML =
                '<tr><td colspan="3">' +
                '<div class="state-block" style="min-height:200px">' +
                '<p class="state-title">No students in this section</p>' +
                '</div></td></tr>';
            return;
        }

        $('#scores-save').disabled = false;
        $('#scores-note').textContent =
            'Applies to all ' + students.length + ' student' + (students.length === 1 ? '' : 's');
        Admin.clearFormErrors('scores-toolbar');
        $('#scores-max-pre').value = commonValue(
            students.map(function (s) {
                return s.pre_test_max_score;
            })
        );
        $('#scores-max-post').value = commonValue(
            students.map(function (s) {
                return s.post_test_max_score;
            })
        );

        $('#scores-tbody').innerHTML = students
            .map(function (s) {
                return (
                    '' +
                    '<tr data-email="' +
                    Admin.esc(s.email) +
                    '" data-name="' +
                    Admin.esc(s.full_name || s.email) +
                    '">' +
                    '<td>' +
                    Admin.userCell(s) +
                    '</td>' +
                    scorePairCell(s, 'pre') +
                    scorePairCell(s, 'post') +
                    '</tr>'
                );
            })
            .join('');

        $$('#scores-tbody .score-pair').forEach(paintScorePair);
    }
    Admin.openScoresModal = openScoresModal;

    function repaintScores(test) {
        Admin.setFieldError('scores-max-' + test, '');
        $$('#scores-tbody .score-pair[data-test="' + test + '"]').forEach(paintScorePair);
    }
    Admin.repaintScores = repaintScores;

    async function saveBatchScores() {
        var rows = $$('#scores-tbody tr[data-email]');
        var updates = [];

        for (var i = 0; i < rows.length; i++) {
            var email = rows[i].getAttribute('data-email');
            var change = {};

            var pairs = $$('.score-pair', rows[i]);
            for (var j = 0; j < pairs.length; j++) {
                var pair = pairs[j];
                var test = pair.getAttribute('data-test');
                var read = Admin.readScorePair(
                    pair.querySelector('[data-part="raw"]').value,
                    sectionMax(test),
                    true
                );

                paintScorePair(pair);
                if (!read.ok) {
                    var rawText = pair.querySelector('[data-part="raw"]').value.trim();
                    if (rawText && !sectionMax(test).trim()) {
                        Admin.setFieldError(
                            'scores-max-' + test,
                            'Enter the highest possible score.'
                        );
                        $('#scores-max-' + test).focus();
                        Admin.toastErr(
                            'Check the ' + Admin.TEST_LABELS[test],
                            'Enter the highest possible score above the table.'
                        );
                    } else {
                        pair.querySelector('[data-part="raw"]').focus();
                        Admin.toastErr(
                            'Check the ' + Admin.TEST_LABELS[test],
                            rows[i].getAttribute('data-name') + ': ' + read.error
                        );
                    }
                    return;
                }

                if (
                    Admin.sameNumber(read.raw, pair.getAttribute('data-initial-raw')) &&
                    Admin.sameNumber(
                        read.max,
                        read.raw == null ? '' : pair.getAttribute('data-initial-max')
                    )
                ) {
                    continue;
                }

                change[test + '_test_raw_score'] = read.raw;
                change[test + '_test_max_score'] = read.max;
            }

            if (Object.keys(change).length) {
                updates.push({ email: email, change: change });
            }
        }

        if (!updates.length) {
            Admin.closeModal('modal-scores');
            Admin.toastOk('Nothing to save', 'No score was changed.');
            return;
        }

        var release = Admin.setBusy($('#scores-save'), 'Saving…');

        var results = await Promise.all(
            updates.map(function (u) {
                return sb.from('profiles').update(u.change).eq('email', u.email);
            })
        );

        release();

        var failed = results.filter(function (r) {
            return r.error;
        });

        if (failed.length) {
            console.error('Batch score save failed:', failed[0].error);
            Admin.toastErr(
                'Scores not saved',
                (Admin.isMissingColumn(failed[0].error)
                    ? Admin.MIGRATION_MISSING
                    : Admin.friendlyDbError(failed[0].error, 'Could not save the scores.')) +
                    (failed.length > 1 ? ' (' + failed.length + ' rows failed)' : '')
            );
            return;
        }

        Admin.closeModal('modal-scores');
        Admin.toastOk(
            'Scores saved',
            updates.length +
                ' student' +
                (updates.length === 1 ? '' : 's') +
                ' updated for ' +
                Admin.state.activeSection +
                '.'
        );
        Admin.refreshAll();
    }
    Admin.saveBatchScores = saveBatchScores;

    Admin.deferredRefresh = false;

    Admin.refreshTimer = null;

    Admin.backoffMs = 1000;
})();
