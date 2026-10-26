/*
 * Stage controls.
 * Open or close each stage for a section, the tutoring schedule, and granting or revoking access.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function gateByKey(key) {
        return Admin.GATES.filter(function (g) {
            return g.key === key;
        })[0];
    }

    function sectionOpen(gate, name) {
        if (gate.open) {
            return true;
        }
        return (
            Array.isArray(Admin.state.overrides) &&
            Admin.state.overrides.some(function (o) {
                return o.stage === gate.key && o.section === name;
            })
        );
    }

    function tickedOpen(gate) {
        return Admin.state.gateSelected[gate.key].filter(function (name) {
            return sectionOpen(gate, name);
        });
    }

    function renderGateAccess() {
        Admin.GATES.forEach(function (gate) {
            Admin.state.gateSelected[gate.key] = Admin.state.gateSelected[gate.key].filter(
                function (name) {
                    return Admin.state.sections.some(function (s) {
                        return s.name === name;
                    });
                }
            );
        });
        renderStageSwitches();
    }
    Admin.renderGateAccess = renderGateAccess;

    function renderStageSwitches() {
        var bar = $('#stage-tabs');
        if (!bar) {
            return;
        }
        var section = window.PIASectionNow || '';
        Admin.GATES.forEach(function (gate) {
            var tab = bar.querySelector('[data-stage-filter="' + gate.label + '"]');
            if (!tab) {
                return;
            }
            var btn = bar.querySelector('[data-gate-switch="' + gate.key + '"]');
            if (!btn) {
                btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'stage-switch';
                btn.setAttribute('role', 'switch');
                btn.setAttribute('data-gate-switch', gate.key);
                tab.insertAdjacentElement('afterend', btn);
            }
            var ready =
                !!section && Admin.state.overrides !== undefined && Admin.state.cohortLoaded;
            var on = ready && sectionOpen(gate, section);
            if (gate.key === 'dash' && ready && Array.isArray(Admin.state.schedules)) {
                var phase = tutPhase(gate, section).phase;
                on = phase === 'open' || phase === 'scheduled';
            }
            btn.hidden = !section;
            btn.setAttribute('aria-checked', on ? 'true' : 'false');
            btn.classList.toggle('is-on', on);
            if (gate.key === 'dash') {
                paintTutoringState(btn, gate, section, ready);
            }
            btn.disabled = !ready || btn.classList.contains('is-working');
            btn.setAttribute(
                'aria-label',
                gate.title + ' for ' + section + (on ? ': open' : ': closed')
            );
            btn.title = !section
                ? ''
                : gate.open
                  ? gate.title +
                    ' is open for every section. Switching it off closes it for all of them.'
                  : on
                    ? 'Open for ' + section + '. Switch off to close it.'
                    : 'Closed for ' + section + '. Switch on to let the section in.';
        });
    }
    Admin.renderStageSwitches = renderStageSwitches;

    async function toggleStage(gate, btn) {
        var section = window.PIASectionNow || '';
        if (!section || btn.classList.contains('is-working')) {
            return;
        }
        btn.classList.add('is-working');
        btn.disabled = true;
        try {
            Admin.state.gateSelected[gate.key] = [section];
            if (gate.key === 'dash' && Array.isArray(Admin.state.schedules)) {
                await toggleTutoring(gate, section);
            } else if (sectionOpen(gate, section)) {
                await revokeSections(gate.key, null);
            } else {
                var members = Admin.state.cohort.filter(function (s) {
                    return s.section === section;
                }).length;
                var ok = await Admin.confirmAction({
                    title: 'Open stage',
                    heading: 'Open ' + gate.title + ' for ' + section + '?',
                    message:
                        members +
                        (members === 1 ? ' student' : ' students') +
                        ' of ' +
                        section +
                        ' can enter it right away. A student who has not finished the stage before it stays out.',
                    confirmLabel: 'Open stage',
                    tone: 'accent'
                });
                if (ok) {
                    await grantSections(gate.key, null);
                }
            }
        } finally {
            Admin.state.gateSelected[gate.key] = [];
            btn.classList.remove('is-working');
            renderStageSwitches();
        }
    }

    var TUT_MONTHS = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
    ];

    var tut = {
        gate: null,
        section: '',
        editing: false,
        calFor: null,
        calMonth: null,
        wired: false
    };

    async function loadTutoringSchedules() {
        var res = await sb.from('tutoring_schedule').select('section, opens_at, closes_at');
        Admin.state.schedules = res.error ? null : res.data || [];
    }
    Admin.loadTutoringSchedules = loadTutoringSchedules;

    function tutSchedule(section) {
        return (
            (Array.isArray(Admin.state.schedules) &&
                Admin.state.schedules.filter(function (r) {
                    return r.section === section;
                })[0]) ||
            null
        );
    }

    function tutPhase(gate, section) {
        if (!sectionOpen(gate, section)) {
            return { phase: 'closed' };
        }
        var row = tutSchedule(section);
        var opens = row && row.opens_at ? Date.parse(row.opens_at) : null;
        var closes = row && row.closes_at ? Date.parse(row.closes_at) : null;
        var now = Date.now();
        if (opens && opens > now) {
            return { phase: 'scheduled', opens: opens, closes: closes };
        }
        if (closes && closes <= now) {
            return { phase: 'autoclosed', closes: closes };
        }
        return { phase: 'open', closes: closes };
    }

    function phParts(ms) {
        var d = new Date(ms + 8 * 3600 * 1000);
        return {
            y: d.getUTCFullYear(),
            mo: d.getUTCMonth() + 1,
            d: d.getUTCDate(),
            h: d.getUTCHours(),
            mi: d.getUTCMinutes()
        };
    }

    function phClock(p) {
        var h12 = p.h % 12 === 0 ? 12 : p.h % 12;
        return h12 + ':' + (p.mi < 10 ? '0' : '') + p.mi + ' ' + (p.h < 12 ? 'AM' : 'PM');
    }

    function phStamp(ms, withDate) {
        var p = phParts(ms);
        return (withDate ? TUT_MONTHS[p.mo - 1] + ' ' + p.d + ', ' : '') + phClock(p);
    }

    function sameDay(a, b) {
        var x = phParts(a),
            y = phParts(b);
        return x.y === y.y && x.mo === y.mo && x.d === y.d;
    }

    function tutLeft(ms) {
        var mins = Math.max(1, Math.round((ms - Date.now()) / 60000));
        return mins < 60
            ? mins + ' min'
            : Math.floor(mins / 60) + ' h ' + (mins % 60 ? (mins % 60) + ' min' : '');
    }

    function tutStatusText(ph) {
        if (ph.phase === 'autoclosed') {
            return {
                cls: 'is-closed',
                text: 'Closed · auto-closed ' + phStamp(ph.closes, !sameDay(ph.closes, Date.now()))
            };
        }
        if (ph.phase === 'scheduled') {
            var when = ph.closes
                ? sameDay(ph.opens, ph.closes)
                    ? phStamp(ph.opens, true) + ' – ' + phStamp(ph.closes, false)
                    : phStamp(ph.opens, true) + ' → ' + phStamp(ph.closes, true)
                : 'opens ' + phStamp(ph.opens, true);
            return { cls: 'is-plain', text: 'Scheduled · ' + when };
        }
        if (ph.phase === 'open') {
            if (!ph.closes) {
                return { cls: 'is-open', text: 'Open' };
            }
            return {
                cls: 'is-open',
                text:
                    ph.closes - Date.now() < 6 * 3600 * 1000
                        ? 'Open · closes in ' + tutLeft(ph.closes)
                        : 'Open · closes ' + phStamp(ph.closes, true)
            };
        }
        return null;
    }

    function paintTutoringState(btn, gate, section, ready) {
        var host = btn.parentNode.querySelector('.stage-state');
        var info =
            ready && Array.isArray(Admin.state.schedules)
                ? tutStatusText(tutPhase(gate, section))
                : null;
        if (!info) {
            if (host) {
                host.remove();
            }
            return;
        }
        if (!host) {
            host = document.createElement('span');
            host.className = 'stage-state';
            btn.insertAdjacentElement('afterend', host);
        }
        var phase = tutPhase(gate, section).phase;
        host.innerHTML =
            '<span class="pill ' +
            info.cls +
            '">' +
            Admin.esc(info.text) +
            '</span>' +
            (phase === 'open' || phase === 'scheduled'
                ? '<button type="button" class="stage-change" data-tut-change>Change</button>'
                : '');
    }

    async function toggleTutoring(gate, section) {
        var ph = tutPhase(gate, section);
        if (ph.phase === 'open' || ph.phase === 'scheduled') {
            Admin.state.gateSelected[gate.key] = [section];
            await revokeSections(gate.key, null);
            if (!sectionOpen(gate, section)) {
                await saveTutoringSchedule(section, null, null, true);
            }
            return;
        }
        openTutoringDialog(gate, section, false);
    }

    async function saveTutoringSchedule(section, opensIso, closesIso, quiet) {
        var res = await sb.rpc('admin_set_tutoring_schedule', {
            p_section: section,
            p_opens: opensIso,
            p_closes: closesIso
        });
        if (res.error) {
            if (!quiet) {
                Admin.toastErr(
                    'Schedule not saved',
                    Admin.friendlyDbError(res.error, 'The request did not complete.')
                );
            }
            return false;
        }
        Admin.state.schedules = (Admin.state.schedules || []).filter(function (r) {
            return r.section !== section;
        });
        if (opensIso || closesIso) {
            Admin.state.schedules.push({
                section: section,
                opens_at: opensIso,
                closes_at: closesIso
            });
        }
        return true;
    }

    function tutRow(which) {
        return $('[data-tut-row="' + which + '"]');
    }

    function tutNum(row, key) {
        return row.querySelector('[data-p="' + key + '"]');
    }

    function tutFill(which, ms) {
        var row = tutRow(which),
            p = phParts(ms),
            h12 = p.h % 12 === 0 ? 12 : p.h % 12;
        tutNum(row, 'mo').value = p.mo < 10 ? '0' + p.mo : p.mo;
        tutNum(row, 'd').value = p.d < 10 ? '0' + p.d : p.d;
        tutNum(row, 'y').value = String(p.y).slice(2);
        tutNum(row, 'h').value = h12;
        tutNum(row, 'mi').value = p.mi < 10 ? '0' + p.mi : p.mi;
        tutAmpm(row, p.h < 12 ? 'AM' : 'PM');
    }

    function tutAmpm(row, ap) {
        $$('[data-ap]', row).forEach(function (b) {
            b.classList.toggle('is-on', b.getAttribute('data-ap') === ap);
        });
    }

    function tutRead(which) {
        var row = tutRow(which);
        var v = function (k) {
            var t = tutNum(row, k).value.trim();
            return /^\d{1,2}$/.test(t) ? parseInt(t, 10) : null;
        };
        var mo = v('mo'),
            d = v('d'),
            y = v('y'),
            h = v('h'),
            mi = v('mi');
        var ap = (row.querySelector('[data-ap].is-on') || {}).textContent;
        if (mo === null || d === null || y === null || h === null || mi === null || !ap) {
            return null;
        }
        if (mo < 1 || mo > 12 || d < 1 || d > 31 || h < 1 || h > 12 || mi > 59) {
            return null;
        }
        var h24 = (h % 12) + (ap === 'PM' ? 12 : 0);
        var stamp = Date.UTC(2000 + y, mo - 1, d, h24, mi) - 8 * 3600 * 1000;
        var back = phParts(stamp);
        return back.mo === mo && back.d === d ? stamp : null;
    }

    function tutCheck() {
        var mode = ($('input[name="tut-mode"]:checked') || {}).value;
        var err = $('#tut-error'),
            sum = $('#tut-summary'),
            msg = '';
        ['start', 'end'].forEach(function (w) {
            tutRow(w)
                .querySelectorAll('.tut-box')
                .forEach(function (b) {
                    b.classList.remove('is-bad');
                });
        });
        $('#tut-sched').classList.toggle('is-off', mode === 'now');
        sum.textContent = '';
        if (mode === 'schedule') {
            var a = tutRead('start'),
                b = tutRead('end');
            if (a === null || b === null) {
                msg = 'Fill in a real date and time for both the start and the end.';
            } else if (b <= a) {
                msg = 'The end must be after the start (' + phStamp(a, true) + ').';
            } else if (b <= Date.now()) {
                msg = 'The end is already past. Pick a later time.';
            } else {
                var mins = Math.round((b - a) / 60000);
                sum.textContent =
                    'Runs ' +
                    (mins >= 60 ? Math.floor(mins / 60) + ' h ' : '') +
                    (mins % 60 ? (mins % 60) + ' min' : '') +
                    ' · students see “Not open yet” until the start.';
            }
            if (msg && a !== null && b !== null) {
                tutRow('end').querySelector('.tut-box').classList.add('is-bad');
            }
        }
        err.hidden = !msg;
        err.textContent = msg;
        $('#tut-accept').textContent = mode === 'now' ? 'Open now' : 'Schedule';
        $('#tut-accept').disabled = !!msg;
        return !msg;
    }

    function openTutoringDialog(gate, section, editing) {
        tut.gate = gate;
        tut.section = section;
        tut.editing = editing;
        tut.calFor = null;
        var members = Admin.state.cohort.filter(function (s) {
            return s.section === section;
        }).length;
        $('#tut-title').textContent =
            (editing ? 'Change game schedule for ' : 'Open the game for ') + section;
        $('#tut-sub').textContent =
            members +
            (members === 1 ? ' student' : ' students') +
            ' of ' +
            section +
            ' can enter. A student who has not finished the stage before it stays out.';
        var row = tutSchedule(section);
        var now = Date.now(),
            start = Math.ceil(now / 300000) * 300000;
        var opens = editing && row && row.opens_at ? Date.parse(row.opens_at) : start;
        var closes = editing && row && row.closes_at ? Date.parse(row.closes_at) : opens + 3600000;
        tutFill('start', opens);
        tutFill('end', closes);
        $('input[name="tut-mode"][value="schedule"]').checked = true;
        $('#tut-cal').hidden = true;
        tutCheck();
        Admin.openModal('modal-tutoring');
    }

    function tutCalRender() {
        var cal = $('#tut-cal'),
            m = tut.calMonth,
            first = new Date(Date.UTC(m.y, m.mo - 1, 1));
        var days = new Date(Date.UTC(m.y, m.mo, 0)).getUTCDate(),
            lead = first.getUTCDay();
        var today = phParts(Date.now()),
            cur = tutRead(tut.calFor),
            sel = cur === null ? null : phParts(cur);
        var html =
            '<div class="tut-cal-head"><button type="button" data-cal-nav="-1" aria-label="Previous month">‹</button><b>' +
            [
                'January',
                'February',
                'March',
                'April',
                'May',
                'June',
                'July',
                'August',
                'September',
                'October',
                'November',
                'December'
            ][m.mo - 1] +
            ' ' +
            m.y +
            '</b><button type="button" data-cal-nav="1" aria-label="Next month">›</button></div><div class="tut-cal-grid">' +
            ['S', 'M', 'T', 'W', 'T', 'F', 'S']
                .map(function (d) {
                    return '<u>' + d + '</u>';
                })
                .join('');
        for (var i = 0; i < lead; i++) {
            html += '<span></span>';
        }
        for (var d = 1; d <= days; d++) {
            var past =
                m.y < today.y ||
                (m.y === today.y && (m.mo < today.mo || (m.mo === today.mo && d < today.d)));
            var cls =
                (m.y === today.y && m.mo === today.mo && d === today.d ? ' is-today' : '') +
                (sel && sel.y === m.y && sel.mo === m.mo && sel.d === d ? ' is-sel' : '');
            html +=
                '<button type="button" data-cal-day="' +
                d +
                '" class="' +
                cls.trim() +
                '"' +
                (past ? ' disabled' : '') +
                '>' +
                d +
                '</button>';
        }
        cal.innerHTML = html + '</div>';
    }

    function wireTutoringDialog() {
        if (tut.wired || !$('#modal-tutoring')) {
            return;
        }
        tut.wired = true;
        var modal = $('#modal-tutoring');

        modal.addEventListener('input', function (event) {
            var el = event.target;
            if (el.matches('[data-p]')) {
                el.value = el.value.replace(/\D/g, '').slice(0, 2);
                if (el.value.length === 2) {
                    var all = $$('input[data-p]', el.closest('.tut-row')),
                        at = all.indexOf(el);
                    if (all[at + 1]) {
                        all[at + 1].focus();
                        all[at + 1].select();
                    }
                }
            }
            tutCheck();
        });
        modal.addEventListener('keydown', function (event) {
            var el = event.target;
            if (
                !el.matches ||
                !el.matches('[data-p]') ||
                (event.key !== 'ArrowUp' && event.key !== 'ArrowDown')
            ) {
                return;
            }
            event.preventDefault();
            var k = el.getAttribute('data-p'),
                n = parseInt(el.value, 10) || 0,
                step = event.key === 'ArrowUp' ? 1 : -1;
            var lim = { mo: [1, 12], d: [1, 31], y: [0, 99], h: [1, 12], mi: [0, 59] }[k];
            n += step;
            if (n > lim[1]) {
                n = lim[0];
            }
            if (n < lim[0]) {
                n = lim[1];
            }
            el.value = k === 'h' ? String(n) : n < 10 ? '0' + n : String(n);
            tutCheck();
        });
        modal.addEventListener('change', function (event) {
            if (event.target.name === 'tut-mode') {
                tutCheck();
            }
        });
        modal.addEventListener('click', function (event) {
            var ap = event.target.closest('[data-ap]');
            if (ap) {
                tutAmpm(ap.closest('.tut-row'), ap.getAttribute('data-ap'));
                tutCheck();
                return;
            }

            var calBtn = event.target.closest('[data-tut-cal]');
            if (calBtn) {
                var which = calBtn.getAttribute('data-tut-cal'),
                    cal = $('#tut-cal');
                if (!cal.hidden && tut.calFor === which) {
                    cal.hidden = true;
                    return;
                }
                var ms = tutRead(which),
                    p = phParts(ms === null ? Date.now() : ms);
                tut.calFor = which;
                tut.calMonth = { y: p.y, mo: p.mo };
                tutCalRender();
                cal.hidden = false;
                return;
            }
            var nav = event.target.closest('[data-cal-nav]');
            if (nav) {
                var m = tut.calMonth,
                    mo = m.mo + parseInt(nav.getAttribute('data-cal-nav'), 10);
                tut.calMonth = {
                    y: m.y + (mo > 12 ? 1 : mo < 1 ? -1 : 0),
                    mo: mo > 12 ? 1 : mo < 1 ? 12 : mo
                };
                tutCalRender();
                return;
            }
            var day = event.target.closest('[data-cal-day]');
            if (day) {
                var row = tutRow(tut.calFor),
                    d = parseInt(day.getAttribute('data-cal-day'), 10),
                    c = tut.calMonth;
                tutNum(row, 'mo').value = c.mo < 10 ? '0' + c.mo : c.mo;
                tutNum(row, 'd').value = d < 10 ? '0' + d : d;
                tutNum(row, 'y').value = String(c.y).slice(2);
                $('#tut-cal').hidden = true;
                tutCheck();
            }
        });

        $('#tut-accept').addEventListener('click', async function () {
            if (!tutCheck()) {
                return;
            }
            var mode = $('input[name="tut-mode"]:checked').value;
            var gate = tut.gate,
                section = tut.section,
                opens = null,
                closes = null;
            if (mode === 'schedule') {
                opens = new Date(tutRead('start')).toISOString();
                closes = new Date(tutRead('end')).toISOString();
            }
            Admin.closeModal(modal);
            var btn = $('[data-gate-switch="' + gate.key + '"]');
            if (btn) {
                btn.classList.add('is-working');
                btn.disabled = true;
            }
            try {
                if (!sectionOpen(gate, section)) {
                    Admin.state.gateSelected[gate.key] = [section];
                    await grantSections(gate.key, null);
                    if (!sectionOpen(gate, section)) {
                        return;
                    }
                }
                var ok = await saveTutoringSchedule(section, opens, closes, false);
                if (ok) {
                    Admin.toastOk(
                        mode === 'now' ? 'Game is open' : 'Game scheduled',
                        mode === 'now'
                            ? section + ' stays open until you close it.'
                            : section +
                                  ': ' +
                                  phStamp(Date.parse(opens), true) +
                                  ' to ' +
                                  phStamp(Date.parse(closes), true) +
                                  '.'
                    );
                }
            } finally {
                Admin.state.gateSelected[gate.key] = [];
                if (btn) {
                    btn.classList.remove('is-working');
                }
                renderStageSwitches();
            }
        });

        var bar = $('#stage-tabs');
        if (bar) {
            bar.addEventListener(
                'click',
                function (event) {
                    if (!event.target.closest('[data-tut-change]')) {
                        return;
                    }
                    event.stopPropagation();
                    var gate = gateByKey('dash'),
                        section = window.PIASectionNow || '';
                    if (section) {
                        openTutoringDialog(gate, section, true);
                    }
                },
                true
            );
        }

        setInterval(function () {
            if (!document.hidden) {
                renderStageSwitches();
            }
        }, 30000);
    }

    function initGates() {
        wireTutoringDialog();
        var tabsBar = $('#stage-tabs');
        if (tabsBar) {
            tabsBar.addEventListener('click', function (event) {
                var sw = event.target.closest('[data-gate-switch]');
                if (!sw) {
                    return;
                }
                event.stopPropagation();
                toggleStage(gateByKey(sw.getAttribute('data-gate-switch')), sw);
            });
        }

        document.addEventListener('pia:section-changed', function () {
            Admin.GATES.forEach(function (gate) {
                Admin.state.gateSelected[gate.key] = [];
            });
            renderGateAccess();
        });
    }
    Admin.initGates = initGates;

    async function grantSections(gateKey, sourceBtn) {
        var gate = gateByKey(gateKey);
        var names = Admin.state.gateSelected[gateKey].slice();
        if (!names.length) {
            return;
        }

        var release = Admin.setBusy(sourceBtn, 'Granting…');
        var granted = [];
        var skipped = [];
        var failed = [];

        for (var i = 0; i < names.length; i++) {
            var res = await sb.rpc('admin_grant_stage', {
                p_stage: gateKey,
                p_emails: null,
                p_section: names[i]
            });
            if (res.error) {
                failed.push({ section: names[i], message: res.error.message });
                continue;
            }
            granted = granted.concat((res.data && res.data.granted) || []);
            skipped = skipped.concat((res.data && res.data.skipped) || []);
        }
        release();

        Admin.state.gateSelected[gateKey] = names.filter(function (name) {
            return failed.some(function (f) {
                return f.section === name;
            });
        });
        await Admin.refreshAll();

        if (!skipped.length && !failed.length) {
            if (granted.length) {
                Admin.toastOk(
                    'Access granted',
                    granted.length +
                        ' student' +
                        (granted.length === 1 ? '' : 's') +
                        ' moved to ' +
                        gate.title +
                        ' from ' +
                        names.join(', ') +
                        '.'
                );
            } else {
                Admin.toastOk(
                    'Nobody new to let in',
                    'Everyone eligible in ' +
                        names.join(', ') +
                        ' is already in ' +
                        gate.title +
                        '.'
                );
            }
            return;
        }

        var lines = skipped
            .slice(0, 8)
            .map(function (item) {
                return '• ' + item.email + ' — ' + item.reason;
            })
            .join('\n');
        var more = skipped.length > 8 ? '\n…and ' + (skipped.length - 8) + ' more.' : '';
        var errors = failed
            .map(function (f) {
                return '• ' + f.section + ' — ' + f.message;
            })
            .join('\n');

        Admin.showNotice(
            granted.length ? 'Partially granted' : 'Nothing granted',
            'Granted: ' +
                granted.length +
                '\nSkipped: ' +
                skipped.length +
                (skipped.length ? '\n\n' + lines + more : '') +
                (failed.length ? '\n\nSections that failed:\n' + errors : ''),
            granted.length ? 'accent' : 'danger'
        );
    }

    async function revokeSections(gateKey, sourceBtn) {
        var gate = gateByKey(gateKey);
        var everyone = gate.open;
        var names = everyone ? [] : tickedOpen(gate);
        if (!everyone && !names.length) {
            return;
        }

        var inside = Admin.state.cohort.filter(function (s) {
            return s.current_stage === gate.label && (everyone || names.indexOf(s.section) !== -1);
        }).length;

        var ok = await Admin.confirmAction({
            title: 'Revoke access',
            heading: everyone
                ? 'Close ' + gate.title + ' for every section?'
                : 'Revoke ' + gate.title + ' for ' + names.join(', ') + '?',
            message:
                (inside
                    ? inside +
                      ' student' +
                      (inside === 1 ? ' is' : 's are') +
                      ' inside now and will return to the ' +
                      'Waiting Room. Anyone part-way through can still finish and submit what they started. '
                    : 'Nobody is inside right now. ') +
                'Nothing already submitted is changed or removed.' +
                (everyone ? '' : ' Other sections keep their access.'),
            confirmLabel: 'Revoke access'
        });
        if (!ok) {
            return;
        }

        var release = Admin.setBusy(sourceBtn, 'Revoking…');
        var res = everyone
            ? await sb.rpc('admin_set_stage_open', { p_stage: gateKey, p_open: false })
            : await sb.rpc('admin_revoke_stage', { p_stage: gateKey, p_sections: names });
        release();

        if (res.error) {
            Admin.toastErr(
                'Access not revoked',
                res.error.code === 'PGRST202' || res.error.code === '42883'
                    ? 'Revoking access is not available: the database is not fully set up. Ask whoever maintains the database to finish its setup, then try again.'
                    : Admin.friendlyDbError(res.error, 'The request did not complete.')
            );
            return;
        }

        gate.open = false;

        if (Array.isArray(Admin.state.overrides)) {
            Admin.state.overrides = Admin.state.overrides.filter(function (o) {
                return o.stage !== gateKey || (!everyone && names.indexOf(o.section) === -1);
            });
        }
        Admin.state.cohort.forEach(function (s) {
            if (s.current_stage === gate.label && (everyone || names.indexOf(s.section) !== -1)) {
                s.current_stage = 'Waiting Room';
            }
        });
        Admin.state.gateSelected[gateKey] = [];
        renderGateAccess();

        var moved = (res.data && (res.data.moved != null ? res.data.moved : res.data.evicted)) || 0;
        Admin.toastOk(
            gate.title + ' revoked',
            (everyone ? 'For every section. ' : names.join(', ') + '. ') +
                (moved
                    ? moved +
                      ' student' +
                      (moved === 1 ? '' : 's') +
                      ' returned to the Waiting Room.'
                    : 'Nobody was inside.')
        );

        Admin.refreshAll();
    }
})();
