/*
 * Math task bank (1 of 3).
 * Loading the questions, the rules, and drawing the topic tabs and table.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function qbDefaultRules() {
        return { mastery: 80, minQuestions: 3, maxErrors: 3 };
    }

    var qb = {
        topic: 'EASY',
        status: 'idle',
        error: '',
        bank: { EASY: [], MEDIUM: [], HARD: [] },
        rules: { EASY: qbDefaultRules(), MEDIUM: qbDefaultRules(), HARD: qbDefaultRules() },
        closesAt: '',
        hasClosing: false,
        scoring: {
            wrong: 20,
            hint: 10,
            fast: 20,
            secs: 30,
            speed: true,
            min: 0,
            repeatOn: false,
            repeatPct: 50
        },
        hasScoring: false,
        genRanges: ['tens', 'hundreds'],
        configSeen: null,
        liveTimer: null,
        dirty: false,
        editingId: null,
        drafts: [],
        stepSeq: 0,
        busy: { edit: false, config: false, bulk: false, drafts: false },
        renderPending: false
    };
    Admin.qb = qb;

    function qbTopicLabel(topic) {
        var t = Admin.QB_TOPICS[topic];
        return 'Topic ' + t.num + ' · ' + t.title;
    }
    Admin.qbTopicLabel = qbTopicLabel;

    function qbParseHint(hintStr) {
        if (!hintStr) {
            return { defaultHint: '', steps: [] };
        }
        try {
            var parsed = JSON.parse(hintStr);
            if (parsed && typeof parsed === 'object') {
                return {
                    defaultHint: typeof parsed.defaultHint === 'string' ? parsed.defaultHint : '',
                    steps: Array.isArray(parsed.steps) ? parsed.steps.map(qbCleanStep) : []
                };
            }
        } catch (err) {}
        return { defaultHint: String(hintStr), steps: [] };
    }

    function qbCleanStep(step) {
        var s = step || {};
        return {
            prompt: String(s.prompt || ''),
            answer: String(s.answer || ''),
            hint1: String(s.hint1 || ''),
            hint2: String(s.hint2 || ''),
            hint3: String(s.hint3 || '')
        };
    }
    Admin.qbCleanStep = qbCleanStep;

    function qbSerializeHint(steps, keepDefault) {
        var fromSteps = steps.length ? steps[0].hint1 : '';
        return JSON.stringify({ defaultHint: fromSteps || keepDefault || '', steps: steps });
    }
    Admin.qbSerializeHint = qbSerializeHint;

    function qbFromRow(row) {
        var hint = qbParseHint(row.hint);
        return {
            id: row.id,
            topic: String(row.difficulty || 'EASY').toUpperCase(),
            q: row.question || '',
            final: row.final_answer || '',
            hint: hint.defaultHint,
            steps: hint.steps,
            points: Admin.toInt(row.points, 10)
        };
    }
    Admin.qbFromRow = qbFromRow;

    function qbScoringFromRow(c) {
        return {
            wrong: Admin.toInt(c.score_wrong_pct, 20),
            hint: Admin.toInt(c.score_hint_pct, 10),
            fast: Admin.toInt(c.score_fast_bonus_pct, 20),
            secs: Admin.toInt(c.score_fast_seconds, 30),
            speed: c.score_speed_bonus !== false,
            min: Admin.toInt(c.score_min, 0),
            repeatOn: c.score_repeat_enabled === true,
            repeatPct: Admin.toInt(c.score_repeat_pct, 50)
        };
    }

    function qbWhole(raw, low, high) {
        var text = String(raw == null ? '' : raw).trim();
        if (!/^-?\d+$/.test(text)) {
            return null;
        }
        var n = Number(text);
        return isFinite(n) && n >= low && n <= high ? n : null;
    }
    Admin.qbWhole = qbWhole;

    function qbExampleScore(base, errors, hints, fast, sc) {
        var raw = base - ((base * sc.wrong) / 100) * errors - ((base * sc.hint) / 100) * hints;
        if (sc.speed && errors === 0 && fast) {
            raw += (base * sc.fast) / 100;
        }
        return Math.max(sc.min, Math.round(raw));
    }

    function qbRenderScoringExample() {
        var sc = qb.scoring,
            n = $('#qb-sc-example');
        var ok =
            qbWhole(sc.wrong, 0, 100) !== null &&
            qbWhole(sc.hint, 0, 100) !== null &&
            qbWhole(sc.fast, 0, 100) !== null &&
            qbWhole(sc.secs, 1, 3600) !== null &&
            qbWhole(sc.min, 0, 500) !== null;
        if (!ok) {
            n.textContent = '';
            return;
        }
        var v = {
            wrong: +sc.wrong,
            hint: +sc.hint,
            fast: +sc.fast,
            secs: +sc.secs,
            speed: sc.speed,
            min: +sc.min
        };
        var bits = [
            'clean ' + qbExampleScore(20, 0, 0, false, v),
            '1 wrong ' + qbExampleScore(20, 1, 0, false, v),
            '1 hint ' + qbExampleScore(20, 0, 1, false, v),
            '1 wrong + 1 hint ' + qbExampleScore(20, 1, 1, false, v)
        ];
        if (v.speed) {
            bits.push(
                'fast and clean (under ' + v.secs + ' s) ' + qbExampleScore(20, 0, 0, true, v)
            );
        }
        n.textContent = 'Example for a 20-point question: ' + bits.join(' · ') + '.';
    }
    Admin.qbRenderScoringExample = qbRenderScoringExample;

    function qbConfigSig(closes, rules, scoring) {
        return JSON.stringify([
            closes || '',
            scoring || null,
            Admin.QB_ORDER.map(function (t) {
                var r = rules[t] || {};
                return [
                    Admin.toInt(r.mastery, 80),
                    Admin.toInt(r.minQuestions, 3),
                    Admin.toInt(r.maxErrors, 3)
                ];
            })
        ]);
    }
    Admin.qbConfigSig = qbConfigSig;

    function qbPoints(raw) {
        var text = String(raw == null ? '' : raw).trim();
        if (!/^\d+$/.test(text)) {
            return null;
        }
        var n = parseInt(text, 10);
        return n >= 1 && n <= Admin.QB_POINTS_MAX ? n : null;
    }
    Admin.qbPoints = qbPoints;

    function qbIntIn(raw, min, max) {
        var text = String(raw == null ? '' : raw).trim();
        if (!/^\d+$/.test(text)) {
            return null;
        }
        var n = parseInt(text, 10);
        return n >= min && n <= max ? n : null;
    }
    Admin.qbIntIn = qbIntIn;

    function qbUniformPoints(list) {
        if (!list.length) {
            return null;
        }
        var first = list[0].points;
        return list.every(function (q) {
            return q.points === first;
        })
            ? first
            : null;
    }
    Admin.qbUniformPoints = qbUniformPoints;

    function qbMissingTable(error) {
        return (
            !!error &&
            (error.code === '42P01' ||
                error.code === 'PGRST205' ||
                /does not exist|could not find the table/i.test(error.message || ''))
        );
    }

    function qbStepSummary(item) {
        var steps = item.steps.length;
        if (!steps) {
            return 'No steps yet';
        }
        var hints = item.steps.reduce(function (n, s) {
            return n + (s.hint1 ? 1 : 0) + (s.hint2 ? 1 : 0) + (s.hint3 ? 1 : 0);
        }, 0);
        return (
            steps +
            (steps === 1 ? ' step' : ' steps') +
            ' · ' +
            hints +
            (hints === 1 ? ' hint' : ' hints')
        );
    }
    Admin.qbStepSummary = qbStepSummary;

    async function loadMathTask() {
        if (qb.status === 'loading') {
            return;
        }
        var wasReady = qb.status === 'ready';
        qb.status = 'loading';
        if (!wasReady) {
            renderQbAll();
        }

        var questions, config;
        try {
            var results = await Promise.all([
                sb.from('question_bank').select(Admin.QB_COLUMNS).order('id'),
                sb.from('app_config').select('*').eq('id', 1).maybeSingle()
            ]);
            questions = results[0];
            config = results[1];
        } catch (err) {
            questions = { error: { message: 'Could not reach the database.' } };
        }

        if (questions.error) {
            qb.status = qbMissingTable(questions.error) ? 'missing' : 'error';
            qb.error = Admin.friendlyDbError(
                questions.error,
                'The question bank could not be loaded.'
            );
            renderQbAll();
            return;
        }
        if (config && config.error) {
            qb.status = 'error';
            qb.error = Admin.friendlyDbError(
                config.error,
                'The game settings could not be loaded.'
            );
            renderQbAll();
            return;
        }

        qb.bank = { EASY: [], MEDIUM: [], HARD: [] };
        (questions.data || []).forEach(function (row) {
            var item = qbFromRow(row);
            if (qb.bank[item.topic]) {
                qb.bank[item.topic].push(item);
            }
        });

        if (config && !config.error && config.data) {
            var c = config.data;
            var serverRules = {};
            Admin.QB_ORDER.forEach(function (topic) {
                var key = topic.toLowerCase();
                serverRules[topic] = {
                    mastery: Admin.toInt(c[key + '_mastery'], 80),
                    minQuestions: Admin.toInt(c[key + '_min_questions'], 3),
                    maxErrors: Admin.toInt(c[key + '_max_errors'], 3)
                };
            });
            var serverCloses = '';
            var serverHasScoring = Object.prototype.hasOwnProperty.call(c, 'score_wrong_pct');
            var serverScoring = serverHasScoring ? qbScoringFromRow(c) : null;
            var sig = qbConfigSig(serverCloses, serverRules, serverScoring);
            var byOther = qb.configSeen !== null && qb.configSeen !== sig;
            qb.configSeen = sig;
            qb.hasClosing = false;
            qb.hasScoring = serverHasScoring;
            if (!qb.dirty) {
                qb.rules = serverRules;
                if (serverScoring) {
                    qb.scoring = serverScoring;
                }
                if (byOther) {
                    Admin.toastOk(
                        'Updated by another admin',
                        'The rules and the scoring on this screen now match what was just saved.'
                    );
                }
            } else if (byOther) {
                Admin.toastErr(
                    'Changed by another admin',
                    'Your unsaved edits were kept. Saving will replace what the other admin just saved.'
                );
            }
        }

        qb.status = 'ready';
        qb.error = '';
        renderQbAll();
    }
    Admin.loadMathTask = loadMathTask;

    function renderQbAll() {
        renderQbChrome();
        renderQbTable();
        Admin.renderQbRules();
    }
    Admin.renderQbAll = renderQbAll;

    // the topic is chosen from the page title, like the section on the Sections page
    function qbPaintTopicMenu() {
        var host = $('#qb-topic-host');
        if (!host) {
            return;
        }
        var menu = host.querySelector('[data-topic-menu]');
        var wasOpen = !!menu && !menu.hidden;
        var now = qb.topic;
        host.innerHTML =
            '<button type="button" data-topic-toggle aria-haspopup="menu" aria-expanded="' +
            wasOpen +
            '">' +
            Admin.esc(Admin.QB_TOPICS[now].title) +
            ' <span aria-hidden="true" style="font-size:.7em;opacity:.8">▾</span></button>' +
            '<div data-topic-menu role="menu"' +
            (wasOpen ? '' : ' hidden') +
            ' class="custom-select-list section-menu">' +
            Admin.QB_ORDER.map(function (t) {
                return (
                    '<button type="button" role="menuitemradio" class="custom-select-option section-opt' +
                    (t === now ? ' is-selected' : '') +
                    '" aria-checked="' +
                    (t === now) +
                    '" data-topic-pick="' +
                    t +
                    '"><span>' +
                    Admin.QB_TOPICS[t].num +
                    ' · ' +
                    Admin.esc(Admin.QB_TOPICS[t].title) +
                    '</span></button>'
                );
            }).join('') +
            '</div>';
    }

    function renderQbChrome() {
        var topic = qb.topic;
        var ready = qb.status === 'ready';

        $$('[data-qb-topic]').forEach(function (btn) {
            var on = btn.getAttribute('data-qb-topic') === topic;
            btn.classList.toggle('is-active', on);
            btn.setAttribute('aria-pressed', String(on));
        });

        $('#qb-title').textContent = qbTopicLabel(topic);
        qbPaintTopicMenu();
        $('#qb-caption').textContent = 'Questions in ' + qbTopicLabel(topic);
        $('#qb-config-sub').textContent =
            'Topic ' + Admin.QB_TOPICS[topic].num + ' · ' + Admin.QB_TOPICS[topic].short;

        $('#qb-add-btn').disabled = !ready;

        var count = $('#nav-count-mathtask');
        if (count) {
            count.textContent = ready
                ? String(
                      Admin.QB_ORDER.reduce(function (n, t) {
                          return n + qb.bank[t].length;
                      }, 0)
                  )
                : '—';
        }
    }
    Admin.renderQbChrome = renderQbChrome;

    function renderQbTable() {
        var tbody = $('#qb-tbody');
        if (tbody.contains(document.activeElement) && qb.status === 'ready') {
            qb.renderPending = true;
            return;
        }
        qb.renderPending = false;

        var list = qb.bank[qb.topic];
        var ready = qb.status === 'ready';
        var loading = qb.status === 'idle' || qb.status === 'loading';
        var empty = $('#qb-empty');

        tbody.textContent = '';
        empty.classList.add('is-hidden');

        if (loading) {
            for (var i = 0; i < 3; i++) {
                tbody.appendChild(Admin.qbSkeletonRow());
            }
            $('#qb-sub').textContent = 'Loading…';
        } else if (!ready) {
            empty.classList.remove('is-hidden');
            $('#qb-empty-title').textContent =
                qb.status === 'missing'
                    ? 'The question bank is not set up yet'
                    : 'The question bank could not be loaded';
            $('#qb-empty-desc').textContent =
                qb.status === 'missing'
                    ? 'The question bank needs to be enabled before it can be used. Ask the system maintainer, then reload the page.'
                    : qb.error + ' Reload the page to try again.';
            $('#qb-sub').textContent = 'Unavailable';
        } else if (!list.length) {
            empty.classList.remove('is-hidden');
            $('#qb-empty-title').textContent = 'No questions in this topic yet';
            $('#qb-empty-desc').textContent = '';
            $('#qb-sub').textContent = 'No questions';
        } else {
            var frag = document.createDocumentFragment();
            list.forEach(function (item, index) {
                frag.appendChild(Admin.qbRow(item, index));
            });
            tbody.appendChild(frag);
            $('#qb-sub').textContent = list.length + (list.length === 1 ? ' question' : ' questions');
        }

        renderQbToolbar();
    }
    Admin.renderQbTable = renderQbTable;

    function renderQbToolbar() {
        var list = qb.bank[qb.topic];
        var usable = qb.status === 'ready' && list.length > 0;

        $('#qb-delete-all').disabled = !usable || qb.busy.bulk;
    }
    Admin.renderQbToolbar = renderQbToolbar;

    function qbCell(className) {
        var td = document.createElement('td');
        td.className = className;
        return td;
    }
    Admin.qbCell = qbCell;
})();
