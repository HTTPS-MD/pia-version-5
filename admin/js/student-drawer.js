/*
 * Student drawer.
 * The side panel for one student: results, tutorial report, retakes and delete.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function findStudent(email) {
        return (
            Admin.state.rosterPage.filter(function (s) {
                return s.email === email;
            })[0] ||
            Admin.state.cohort.filter(function (s) {
                return s.email === email;
            })[0] ||
            null
        );
    }
    Admin.findStudent = findStudent;

    function openStudentDrawer(email, trigger) {
        var s = findStudent(email);
        if (!s) {
            return;
        }

        Admin.state.activeStudent = s;
        var condition = Admin.CONDITIONS[s.group_type] || { short: s.group_type || '—', badge: '' };

        $('#drawer-initials').textContent = Admin.initialsOf(s.full_name, s.email);

        var drawerOnline = Admin.isOnline(s);
        var drawerDot = $('#drawer-presence');
        if (drawerDot) {
            drawerDot.classList.toggle('is-hidden', drawerOnline === null);
            drawerDot.classList.toggle('is-online', drawerOnline === true);
            drawerDot.setAttribute('data-presence', s.email);
            drawerDot.title = drawerOnline ? 'Signed in' : 'Signed out';
        }
        $('#drawer-student-name').textContent = s.full_name || '(no name)';
        $('#drawer-condition').textContent = condition.short;
        $('#drawer-section').textContent = s.section || '—';
        var numberCell = $('#drawer-number');
        if (numberCell && window.PIACheckin && window.PIACheckin.loadNumber) {
            window.PIACheckin.loadNumber(numberCell, s.email);
        }
        $('#drawer-stage').textContent = Admin.stageLabel(Admin.stageOf(s));
        $('#drawer-tutor').textContent = Admin.tutorLabel(s);

        var controlNote = $('#drawer-control-note');
        var beyondOcean =
            s.group_type === 'control' &&
            (s.is_in_game === true ||
                s.current_stage === 'Character Selection' ||
                s.current_stage === 'Tutoring Dashboard');
        controlNote.classList.add('is-hidden');
        controlNote.textContent = '';

        var reselect = $('[data-student-action="retake-character"]');
        if (reselect) {
            reselect.classList.toggle('is-hidden', s.group_type !== 'non-assigned');
        }
        ['pre', 'post'].forEach(function (test) {
            var parts = Admin.scoreParts(s, test);
            $('#drawer-' + test).textContent = parts.value;
            $('#drawer-' + test + '-detail').textContent = parts.detail;
        });

        renderTraits(s);
        renderTutorialReport(s);
        Admin.openModal('drawer-student', trigger);
    }
    Admin.openStudentDrawer = openStudentDrawer;

    function gameTopicLabel(topic) {
        return { 1: 'Easy', 2: 'Medium', 3: 'Hard' }[Number(topic)] || '—';
    }

    function gameDuration(seconds) {
        if (seconds == null || !Number.isFinite(Number(seconds))) {
            return '—';
        }
        var s = Math.max(0, Math.floor(Number(seconds)));
        var h = Math.floor(s / 3600),
            m = Math.floor((s % 3600) / 60);
        return h ? h + 'h ' + m + 'm' : m ? m + 'm ' + (s % 60) + 's' : s + 's';
    }

    function gameStat(label, value) {
        return (
            '<div class="game-report-stat"><span class="game-report-stat-label">' +
            Admin.esc(label) +
            '</span><strong class="game-report-stat-value">' +
            Admin.esc(value) +
            '</strong></div>'
        );
    }

    function formatDay(value) {
        var d = new Date(String(value) + 'T00:00:00');
        return isNaN(d.getTime())
            ? String(value)
            : d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
    }

    async function renderTutorialReport(s) {
        var performance = $('#drawer-tutorial-performance');
        var history = $('#drawer-session-history');
        performance.innerHTML = noticeHtml('info', 'Loading game records', '');
        history.innerHTML = '';
        performance.setAttribute('aria-busy', 'true');
        history.setAttribute('aria-busy', 'true');

        var both = await Promise.all([
            sb.rpc('pia_admin_tutorial_report', { p_student_email: s.email }),
            sb.rpc('pia_admin_daily_report', { p_student_email: s.email })
        ]);
        var res = both[0];
        var daily = both[1] && !both[1].error && both[1].data ? both[1].data : null;
        if (Admin.state.activeStudent !== s) {
            return;
        }
        performance.removeAttribute('aria-busy');
        history.removeAttribute('aria-busy');

        if (res.error || !res.data || !res.data.summary || !Array.isArray(res.data.history)) {
            performance.innerHTML = noticeHtml(
                'alert',
                'Could not load game records',
                res.error
                    ? Admin.friendlyDbError(res.error, 'Unknown database error.')
                    : 'The admin tutorial report is not available yet.'
            );
            history.innerHTML = '';
            return;
        }

        var summary = res.data.summary;
        if (!Number(summary.sessions)) {
            performance.innerHTML = noticeHtml(
                'info',
                'No tutoring activity yet',
                'Game performance will appear after this student starts a timed session.'
            );
            history.innerHTML = noticeHtml('info', 'No sessions yet', '');
            return;
        }

        performance.innerHTML =
            '<div class="game-report-grid">' +
            gameStat('Best level', gameTopicLabel(summary.best_topic)) +
            gameStat(
                'Average speed',
                summary.avg_speed_seconds == null ? '—' : gameDuration(summary.avg_speed_seconds)
            ) +
            gameStat(
                'Accuracy',
                summary.accuracy_percent == null ? '—' : Number(summary.accuracy_percent) + '%'
            ) +
            gameStat(
                daily ? 'Active time' : 'Sessions',
                daily ? gameDuration(daily.active_seconds_total) : Number(summary.sessions)
            ) +
            gameStat('Total points', Number(summary.score_sum) || 0) +
            gameStat('Total errors', Number(summary.errors) || 0) +
            '</div>';

        if (daily) {
            history.innerHTML = daily.days.length
                ? '<div class="game-history-list">' +
                  daily.days
                      .map(function (d) {
                          var pct = d.questions ? Math.round((d.clean * 100) / d.questions) : 0;
                          return (
                              '<div class="game-history-row"><div class="game-history-top"><span>' +
                              Admin.esc(formatDay(d.day)) +
                              '</span><span>' +
                              Admin.esc(gameDuration(d.active_seconds)) +
                              ' active</span></div>' +
                              '<div class="game-history-meta"><span>Questions: ' +
                              Admin.esc(d.questions) +
                              '</span><span>Accuracy: ' +
                              Admin.esc(pct) +
                              '%</span><span>Points: ' +
                              Admin.esc(d.points) +
                              '</span><span>Errors: ' +
                              Admin.esc(d.errors) +
                              '</span><span>Hints: ' +
                              Admin.esc(d.hints) +
                              '</span></div></div>'
                          );
                      })
                      .join('') +
                  '</div>'
                : noticeHtml('info', 'No questions answered yet', '');
            return;
        }

        history.innerHTML =
            '<div class="game-history-list">' +
            res.data.history
                .map(function (row) {
                    return (
                        '<div class="game-history-row"><div class="game-history-top"><span>' +
                        Admin.esc(formatStamp(row.started_at)) +
                        '</span><span>' +
                        Admin.esc(row.status === 'active' ? 'Active' : 'Ended') +
                        '</span></div>' +
                        '<div class="game-history-meta"><span>Difficulty: ' +
                        Admin.esc(gameTopicLabel(row.best_topic)) +
                        '</span><span>Duration: ' +
                        Admin.esc(gameDuration(row.duration_seconds)) +
                        '</span><span>Points: ' +
                        Admin.esc(Number(row.score_sum) || 0) +
                        '</span><span>Errors: ' +
                        Admin.esc(Number(row.errors) || 0) +
                        '</span><span>Questions: ' +
                        Admin.esc(Number(row.completed_questions) || 0) +
                        '</span><span>Hints: ' +
                        Admin.esc(Number(row.hints) || 0) +
                        '</span></div></div>'
                    );
                })
                .join('') +
            '</div>';
    }

    var BFPT = window.PIA_BFPT || null;

    var BFPT_COLUMNS =
        'email, responses, ocean_e, ocean_a, ocean_c, ocean_n, ocean_o,' +
        ' submitted_at, scoring_key, source';

    var BFPT_TRAITS = [
        { key: 'ocean_e', name: 'Extroversion' },
        { key: 'ocean_a', name: 'Agreeableness' },
        { key: 'ocean_c', name: 'Conscientiousness' },
        { key: 'ocean_n', name: 'Neuroticism' },
        { key: 'ocean_o', name: 'Openness to Experience' }
    ];

    function noticeHtml(iconName, title, text) {
        return (
            '<div class="notice">' +
            Admin.icon(iconName) +
            '<div><p class="notice-title">' +
            Admin.esc(title) +
            '</p>' +
            (text ? '<p class="notice-text">' + Admin.esc(text) + '</p>' : '') +
            '</div></div>'
        );
    }

    function formatStamp(iso) {
        var d = new Date(iso);
        return isNaN(d.getTime())
            ? '—'
            : d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
    }

    async function fetchResults(email) {
        var query = sb.from('ocean_submissions').select(BFPT_COLUMNS);
        if (email) {
            query = query.eq('email', email);
        }
        return query
            .order('submitted_at', { ascending: false })
            .order('id', { ascending: false })
            .limit(5000);
    }

    async function renderTraits(s) {
        var box = $('#drawer-traits');
        $('#drawer-ocean-meta').textContent = '';
        box.innerHTML = Admin.skeletonTraits();
        box.setAttribute('aria-busy', 'true');

        var res = await fetchResults(s.email);
        box.removeAttribute('aria-busy');

        if (Admin.state.activeStudent !== s) {
            return;
        }

        if (res.error) {
            box.innerHTML = noticeHtml(
                'alert',
                'Could not load results',
                Admin.friendlyDbError(res.error, 'Unknown database error.')
            );
            return;
        }

        var rows = res.data || [];
        if (!rows.length) {
            box.innerHTML = noticeHtml(
                'info',
                'No result yet',
                s.is_ocean_done
                    ? 'Marked complete, but no stored result was found. Allow a retake to collect one.'
                    : ''
            );
            return;
        }

        var r = rows[0];

        var scores = BFPT_TRAITS.map(function (t) {
            var v = r[t.key];
            var width = v == null ? 0 : Math.max(0, Math.min(100, (v / Admin.OCEAN_MAX) * 100));
            return (
                '' +
                '<div class="trait">' +
                '<div class="trait-top">' +
                '<span class="trait-name">' +
                Admin.esc(t.name) +
                '</span>' +
                '<span class="trait-val tnum">' +
                (v == null
                    ? 'n/a'
                    : Admin.esc(v) + '<span class="trait-of"> / ' + Admin.OCEAN_MAX + '</span>') +
                '</span>' +
                '</div>' +
                '<div class="bar"><div class="bar-fill" style="width:' +
                width +
                '%"></div></div>' +
                '</div>'
            );
        }).join('');

        var meta =
            'Submitted ' +
            Admin.esc(formatStamp(r.submitted_at)) +
            (rows.length > 1 ? ' · latest of ' + rows.length + ' attempts' : '');
        var matchingNote = '';

        $('#drawer-ocean-meta').textContent = meta;
        box.innerHTML = scores;
    }

    function initDrawerActions() {
        $$('[data-student-action]').forEach(function (btn) {
            btn.addEventListener('click', function () {
                var s = Admin.state.activeStudent;
                if (!s) {
                    return;
                }
                var action = btn.getAttribute('data-student-action');

                if (action === 'edit') {
                    Admin.closeModal('drawer-student');
                    Admin.openEditStudent(s.email);
                } else if (action === 'retake-ocean') {
                    allowRetakeOcean(s.email);
                } else if (action === 'retake-character') {
                    allowRetakeCharacter(s.email);
                } else if (action === 'delete') {
                    deleteStudent(s.email);
                }
            });
        });
    }
    Admin.initDrawerActions = initDrawerActions;


    async function allowRetakeOcean(email) {
        var ok = await Admin.confirmAction({
            heading: 'Let ' + Admin.whoIs(email) + ' retake OCEAN?',
            message:
                'They answer all 50 items again. The current result stays in the history, and the new one replaces it when they finish.',
            confirmLabel: 'Allow retake'
        });
        if (!ok) {
            return;
        }

        var res = await sb
            .from('profiles')
            .update({
                is_ocean_done: false,
                current_stage: 'OCEAN',
                stage_started_at: new Date().toISOString()
            })
            .eq('email', email);

        if (res.error) {
            Admin.toastErr(
                'Could not allow retake',
                Admin.friendlyDbError(res.error, 'Update rejected.')
            );
            return;
        }

        Admin.toastOk('OCEAN retake enabled', Admin.whoIs(email) + ' can take the inventory again.');
        Admin.closeModal('drawer-student');
        Admin.refreshAll();
    }

    async function allowRetakeCharacter(email) {
        var ok = await Admin.confirmAction({
            heading: 'Clear the tutor for ' + Admin.whoIs(email) + '?',
            message: 'They go back to choosing a character.',
            confirmLabel: 'Clear selection'
        });
        if (!ok) {
            return;
        }

        var res = await sb
            .from('profiles')
            .update({
                selected_character: null,
                current_stage: 'Character Selection',
                stage_started_at: new Date().toISOString()
            })
            .eq('email', email);

        if (res.error) {
            Admin.toastErr(
                'Could not allow re-selection',
                Admin.friendlyDbError(res.error, 'Update rejected.')
            );
            return;
        }

        Admin.toastOk('Character re-selection enabled', Admin.whoIs(email) + ' can pick a persona again.');
        Admin.closeModal('drawer-student');
        Admin.refreshAll();
    }

    async function deleteStudent(email) {
        var ok = await Admin.confirmAction({
            heading: 'Delete ' + Admin.whoIs(email) + '?',
            message:
                'Their profile, account and every response are removed. This cannot be undone and changes your dataset.',
            confirmLabel: 'Delete permanently'
        });
        if (!ok) {
            return;
        }

        var res = await sb.rpc('admin_delete_user', { target_email: email });

        if (res.error) {
            Admin.toastErr(
                'Deletion failed',
                Admin.friendlyDbError(res.error, 'The account was not deleted.')
            );
            return;
        }

        Admin.closeModal('drawer-student');
        Admin.toastOk('Participant deleted', Admin.whoIs(email) + ' was removed from the study.');
        Admin.refreshAll();
    }

    var TUTORS = [
        { key: 'pia-open', name: 'Ava (Openness)' },
        { key: 'pia-conscientious', name: 'Cara (Conscientiousness)' },
        { key: 'pia-extravert', name: 'Theo (Extraversion)' },
        { key: 'pia-agreeable', name: 'Amy (Agreeableness)' },
        { key: 'pia-calm', name: 'Kai (Neuroticism)' },
        { key: 'pia-neutral', name: 'Noel (Neutral)' }
    ];
    Admin.TUTORS = TUTORS;
})();
