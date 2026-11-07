/*
 * Stage controls.
 * Open or close each stage for a section, and granting or revoking access.
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
        var bar = $('#stage-let');
        if (!bar) {
            return;
        }
        var section = window.PIASectionNow || '';
        // While the door is open (the session is running) there is nothing to do with the stages: a short note takes their place.
        var running = !!section && !!window.PIASessionLive;
        // The stage controls show up after End. Before that they stay out of the way, unless a stage is still open
        // (left open from before): then they show, so it can be closed.
        var anyOpen = !!section && Admin.GATES.some(function (g) {
            return sectionOpen(g, section);
        });
        var ended = window.PIASessionState === 'locked' || window.PIASessionState === 'ended';
        // The experiment is over once the Game was closed for the section (and no stage is open again): the switches step
        // aside, with a short note and a way to bring them back.
        var finished = !!section && !running && !anyOpen && window.PIAGameClosed === section;
        // Once the experiment is over the whole bar steps aside (the button says "Experiment ended").
        // the gate button says "Experiment ended" only when the bar is hidden because of this
        var wasFinished = window.PIAStagesFinished;
        var wasOpen = window.PIAStagesOpen;
        window.PIAStagesFinished = finished;
        window.PIAStagesOpen = anyOpen;
        if ((wasFinished !== finished || wasOpen !== anyOpen) && window.PIACheckin) window.PIACheckin.refresh();
        bar.hidden = !section || finished || running || !(ended || anyOpen);
        var label = bar.querySelector('.stage-label');
        var items = bar.querySelector('.stage-items');
        if (label) {
            label.classList.toggle('is-hidden', running || finished);
        }
        if (items) {
            items.classList.toggle('is-hidden', running || finished);
        }
        Admin.GATES.forEach(function (gate) {
            var btn = bar.querySelector('[data-gate-switch="' + gate.key + '"]');
            if (!btn) {
                var item = document.createElement('span');
                item.className = 'stage-item';
                btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'stage-switch';
                btn.setAttribute('role', 'switch');
                btn.setAttribute('data-gate-switch', gate.key);
                var name = document.createElement('span');
                name.className = 'stage-name';
                name.textContent = gate.label === 'Tutoring Dashboard' ? 'Game' : gate.label === 'Character Selection' ? 'Choose tutor' : 'OCEAN test';
                item.appendChild(btn);
                item.appendChild(name);
                $('#stage-items').appendChild(item);
            }
            var ready =
                !!section && Admin.state.overrides !== undefined && Admin.state.cohortLoaded;
            var on = ready && sectionOpen(gate, section);
            btn.hidden = !section;
            btn.setAttribute('aria-checked', on ? 'true' : 'false');
            btn.classList.toggle('is-on', on);
            var locked = !!window.PIASessionLive;
            // The session has not started: nobody can be let in, so a closed stage cannot be opened.
            var notStarted = window.PIASessionState === 'none' && !on;
            btn.disabled = !ready || locked || notStarted || btn.classList.contains('is-working');
            btn.setAttribute(
                'aria-label',
                gate.title + ' for ' + section + (on ? ': open' : ': closed')
            );
            btn.title = !section
                ? ''
                : notStarted
                  ? 'Open the gate, then close it, first.'
                  : locked
                  ? 'Close the gate first. The stages stay locked while students are entering.'
                  : gate.open
                  ? gate.title +
                    ' is open for every section. Switching it off closes it for all of them.'
                  : on
                    ? 'Open for ' + section + '. Switch off to close it.'
                    : 'Closed for ' + section + '. Switch on to let the section in.';
        });
    }
    Admin.renderStageSwitches = renderStageSwitches;

    // The stages before this one that are open for this section only (not for everyone), so each can be closed on its own.
    function earlierOpenGates(gate, section) {
        return Admin.GATES.slice(0, Admin.GATES.indexOf(gate)).filter(function (g) {
            return !g.open && sectionOpen(g, section);
        });
    }
    function insideStage(gate, section) {
        return Admin.state.cohort.filter(function (s) {
            return s.section === section && s.email && s.current_stage === gate.label;
        });
    }

    // Why a student cannot enter a stage yet (null = can enter). The same rules as admin_grant_stage in the database.
    function stayOutReason(gate, s) {
        var group = String(s.group_type || '').toLowerCase().replace('_', '-');
        if (!s.is_ocean_done) {
            return 'Has not finished the OCEAN test';
        }
        if (gate.key === 'char' && group !== 'non-assigned') {
            if (group === 'control') {
                return 'Control group, has no tutor to choose';
            }
            return 'Is given a tutor, nothing to choose';
        }
        if (gate.key === 'char' && s.selected_character) {
            return Admin.tutorLabel(s);
        }
        if (gate.key === 'dash' && group === 'control') {
            return 'Control group does not play the Game';
        }
        if (gate.key === 'dash' && group === 'non-assigned' && !s.selected_character) {
            return 'Has not chosen a tutor yet';
        }
        return null;
    }

    // "(Control)", "(Free Choice)", "(Neutral)" or "(Assigned)" after the status of a student in the question
    var GROUP_NAMES = { control: 'Control', 'non-assigned': 'Free Choice', neutral: 'Neutral', assigned: 'Assigned' };
    function withGroup(email, status) {
        var who = (Admin.state.cohort || []).filter(function (c) {
            return String(c.email || '').toLowerCase() === String(email || '').toLowerCase();
        })[0];
        var group = String((who && who.group_type) || '').toLowerCase().replace('_', '-');
        var name = GROUP_NAMES[group];
        if (!name) {
            return status;
        }
        if (status && typeof status === 'object') {
            return { text: status.text + ' (' + name + ')', tone: status.tone };
        }
        return status + ' (' + name + ')';
    }

    // The question before a stage opens: who can enter and who stays out.
    async function openStageDialog(gate, section) {
        var dialog = {
            heading: 'Open ' + gate.title + ' for ' + section + '?',
            confirmLabel: 'Open stage',
            tone: 'accent'
        };
        if (gate.key === 'ocean') {
            // The session has ended: students who entered can take the test, the others cannot enter anymore.
            var marks = window.PIASessionRows ? await window.PIASessionRows(section) : null;
            if (!marks || !marks.length) {
                dialog.message = 'Students who entered can start the test.';
                return dialog;
            }
            // Entered and not finished: can enter. Entered but already finished: left alone (opening OCEAN never resets them).
            var done = {};
            Admin.state.cohort.forEach(function (c) {
                done[String(c.email || '').toLowerCase()] = !!c.is_ocean_done;
            });
            var enter = [];
            var finished = [];
            var never = [];
            marks.forEach(function (m) {
                var who = Admin.studentLabel(m.email);
                if (!m.entered) {
                    never.push([who, withGroup(m.email, { text: 'Did not enter', tone: 'bad' })]);
                } else if (done[String(m.email).toLowerCase()]) {
                    finished.push([who, withGroup(m.email, 'Already finished the OCEAN test')]);
                } else {
                    enter.push([who, withGroup(m.email, { text: 'Can enter', tone: 'good' })]);
                }
            });
            dialog.message =
                enter.length + ' can enter. ' + finished.length + ' already finished. ' + never.length + ' did not enter.';
            dialog.table = { columns: ['Student', 'Status'], rows: never.concat(finished, enter) };
            if (!enter.length) {
                dialog.blocked = true;
                dialog.message = 'Nobody can enter the OCEAN test. Everyone has already finished it or did not enter.';
            }
            return dialog;
        }
        var stay = [];
        var enter = [];
        // Students who never entered today's session cannot sign in, so they stay out of every stage.
        var marks = window.PIASessionRows ? await window.PIASessionRows(section) : null;
        var entered = null;
        if (marks && marks.length) {
            entered = {};
            marks.forEach(function (m) {
                entered[String(m.email).toLowerCase()] = !!m.entered;
            });
        }
        Admin.state.cohort.forEach(function (s) {
            if (s.section !== section || !s.email) {
                return;
            }
            if (entered && !entered[String(s.email).toLowerCase()]) {
                stay.push([Admin.studentLabel(s.email), withGroup(s.email, { text: 'Did not enter', tone: 'warn' })]);
                return;
            }
            var inEarlier = earlierOpenGates(gate, section).filter(function (g) {
                return s.current_stage === g.label;
            })[0];
            var why = inEarlier ? 'Still in the ' + inEarlier.title : stayOutReason(gate, s);
            (why ? stay : enter).push([
                Admin.studentLabel(s.email),
                withGroup(s.email, why ? { text: why, tone: 'warn' } : { text: 'Can enter', tone: 'good' })
            ]);
        });
        dialog.message = enter.length + ' can enter. ' + stay.length + ' stay out.';
        earlierOpenGates(gate, section).forEach(function (before) {
            var still = insideStage(before, section).length;
            dialog.message += still
                ? ' ' + before.title + ' stays open: ' + still + (still === 1 ? ' student is' : ' students are') + ' still inside.'
                : ' ' + before.title + ' closes now, nobody is inside.';
        });
        dialog.table = { columns: ['Student', 'Status'], rows: stay.concat(enter) };
        // Nobody could get in: the stage is not opened at all.
        if (!enter.length) {
            dialog.blocked = true;
            dialog.message =
                'Nobody can enter ' +
                (gate.key === 'dash' ? 'the Game' : gate.title) +
                ' yet. Students must finish the OCEAN test' +
                (gate.key === 'dash' ? ' and, if they choose their tutor, choose it' : '') +
                ' first.';
        }
        return dialog;
    }

    async function toggleStage(gate, btn) {
        var section = window.PIASectionNow || '';
        if (!section || window.PIASessionLive || btn.classList.contains('is-working')) {
            return;
        }
        if (window.PIASessionState === 'none' && !sectionOpen(gate, section)) {
            return;
        }
        btn.classList.add('is-working');
        btn.disabled = true;
        try {
            Admin.state.gateSelected[gate.key] = [section];
            if (sectionOpen(gate, section)) {
                await revokeSections(gate.key, null);
                return;
            }
            var preview = await openStageDialog(gate, section);
            if (preview.blocked) {
                Admin.showNotice('Cannot open ' + gate.title + ' yet', preview.message, 'danger', preview.table);
            } else if (await Admin.confirmAction(preview)) {
                await grantSections(gate.key, null);
            }
        } finally {
            Admin.state.gateSelected[gate.key] = [];
            btn.classList.remove('is-working');
            renderStageSwitches();
        }
    }

    // For the End dialog: can this stage open for the section, and open it without asking again.
    Admin.previewStage = function (key, section) {
        return openStageDialog(gateByKey(key), section);
    };
    Admin.stageIsOpen = function (key, section) {
        return sectionOpen(gateByKey(key), section);
    };
    Admin.openStageNow = async function (key, section) {
        Admin.state.gateSelected[key] = [section];
        try {
            await grantSections(key, null);
        } finally {
            Admin.state.gateSelected[key] = [];
            renderStageSwitches();
        }
    };

    function initGates() {
        var tabsBar = $('#stage-let');
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

        // An earlier stage closes by itself once nobody is inside it (a student still inside keeps it open).
        for (var c = 0; c < names.length; c++) {
            if (failed.some(function (f) { return f.section === names[c]; })) {
                continue;
            }
            var empties = earlierOpenGates(gate, names[c]).filter(function (g) {
                return !insideStage(g, names[c]).length;
            });
            for (var e = 0; e < empties.length; e++) {
                Admin.state.gateSelected[empties[e].key] = [names[c]];
                await revokeSections(empties[e].key, null, true);
            }
        }

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

        // the students who could not enter, as a table: who and why
        var parts = [granted.length + ' let in · ' + skipped.length + ' not ready'];
        failed.forEach(function (f) {
            parts.push('Could not open ' + f.section + ': ' + Admin.teacherWords(f.message));
        });

        Admin.showNotice(
            granted.length
                ? 'Some students are not ready for ' + gate.title
                : 'No one could enter ' + gate.title,
            parts.join('\n'),
            granted.length ? 'accent' : 'danger',
            {
                columns: ['Student', 'Why'],
                rows: skipped.map(function (item) {
                    return [Admin.studentLabel(item.email), plainReason(item.reason, item.email)];
                })
            }
        );
    }

    function plainReason(reason, email) {
        var text = String(reason || '').trim();
        // choosing a tutor only applies to the free-choice group: the others are skipped on purpose
        if (/does not apply/i.test(text)) {
            var who = (Admin.state.cohort || []).filter(function (c) {
                return String(c.email || '').toLowerCase() === String(email || '').toLowerCase();
            })[0];
            var group = who && who.group_type;
            if (group === 'assigned') {
                return 'Already has an assigned tutor';
            }
            if (group === 'control') {
                return 'Control group has no tutor to choose';
            }
            if (group === 'neutral') {
                return 'Already has an assigned tutor';
            }
            return 'Does not choose a tutor';
        }
        if (/ocean/i.test(text) && /not.*complet/i.test(text)) {
            return 'Has not finished the OCEAN test';
        }
        if (/character/i.test(text) && /select|chosen|choose/i.test(text)) {
            return 'Has not chosen a character yet';
        }
        return text.replace(/\.$/, '') || 'Not eligible';
    }

    async function revokeSections(gateKey, sourceBtn, silent) {
        var gate = gateByKey(gateKey);
        var everyone = gate.open;
        var names = everyone ? [] : tickedOpen(gate);
        if (!everyone && !names.length) {
            return;
        }

        var inside = Admin.state.cohort.filter(function (s) {
            return s.current_stage === gate.label && s.email && (everyone || names.indexOf(s.section) !== -1);
        });
        var manySections = everyone || names.length > 1;
        // Closing the Game for one section ends the experiment: everyone still online is signed out in the same step.
        var online = [];
        var endsExperiment = gate.key === 'dash' && !everyone && names.length === 1;
        if (endsExperiment && window.PIASignOut) {
            online = await window.PIASignOut.online(names[0]).catch(function () {
                return [];
            });
        }
        var insideNow = inside.map(function (s) {
            return String(s.email).toLowerCase();
        });

        var ok =
            silent ||
            (await Admin.confirmAction({
                heading: everyone
                    ? 'Close ' + gate.title + ' for every section?'
                    : endsExperiment
                      ? 'End experiment for ' + names[0] + '?'
                      : 'Close ' + gate.title + ' for ' + names.join(', ') + '?',
                message:
                    (online.length
                        ? 'Everyone below is signed out.'
                        : inside.length
                          ? inside.length + (inside.length === 1 ? ' student goes' : ' students go') + ' back to the Waiting Room.'
                          : '') +
                    (endsExperiment ? (online.length || inside.length ? ' ' : '') + 'The stages stay hidden until tomorrow.' : ''),
                table: online.length
                    ? {
                          columns: ['Student', 'Now'],
                          rows: online.map(function (e) {
                              return [
                                  Admin.studentLabel(e),
                                  { text: (insideNow.indexOf(e) !== -1 ? 'In the Game' : 'Online') + ' · will be signed out', tone: 'warn' }
                              ];
                          })
                      }
                    : {
                    columns: manySections ? ['Student', 'Section', 'Now'] : ['Student', 'Now'],
                    rows: inside.map(function (s) {
                        var row = [Admin.studentLabel(s.email), { text: 'Inside · goes back to the Waiting Room', tone: 'warn' }];
                        if (manySections) {
                            row.splice(1, 0, s.section);
                        }
                        return row;
                    })
                },
                confirmLabel: online.length
                    ? 'End experiment'
                    : endsExperiment
                      ? 'End experiment'
                      : 'Close stage'
        }));
        if (!ok) {
            return;
        }

        var release = Admin.setBusy(sourceBtn, 'Closing…');
        var res = everyone
            ? await sb.rpc('admin_set_stage_open', { p_stage: gateKey, p_open: false })
            : await sb.rpc('admin_revoke_stage', { p_stage: gateKey, p_sections: names });
        release();

        if (res.error) {
            Admin.toastErr(
                'Stage not closed',
                res.error.code === 'PGRST202' || res.error.code === '42883'
                    ? 'Revoking access is not available: the database is not fully set up. Ask whoever maintains the database to finish its setup, then try again.'
                    : Admin.friendlyDbError(res.error, 'The request did not complete.')
            );
            return;
        }

        gate.open = false;
        if (online.length && window.PIASignOut) {
            window.PIASignOut.signOut(online);
        }
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
            gate.title + ' closed',
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
