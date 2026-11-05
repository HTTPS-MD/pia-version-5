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
        bar.hidden = !section;
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
            btn.disabled = !ready || locked || btn.classList.contains('is-working');
            btn.setAttribute(
                'aria-label',
                gate.title + ' for ' + section + (on ? ': open' : ': closed')
            );
            btn.title = !section
                ? ''
                : locked
                  ? 'End attendance first. Stages stay locked while attendance is open.'
                  : gate.open
                  ? gate.title +
                    ' is open for every section. Switching it off closes it for all of them.'
                  : on
                    ? 'Open for ' + section + '. Switch off to close it.'
                    : 'Closed for ' + section + '. Switch on to let the section in.';
        });
    }
    Admin.renderStageSwitches = renderStageSwitches;

    // The stage before this one, when it is open for this section only (not for everyone) and so can be closed on its own.
    function earlierOpenGate(gate, section) {
        var prev = Admin.GATES[Admin.GATES.indexOf(gate) - 1];
        return prev && !prev.open && sectionOpen(prev, section) ? prev : null;
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
            return 'Is given a tutor, nothing to choose';
        }
        if (gate.key === 'dash' && group === 'non-assigned' && !s.selected_character) {
            return 'Has not chosen a tutor yet';
        }
        return null;
    }

    // The question before a stage opens. OCEAN has no earlier stage: Present students enter. The others list who can enter and who stays out.
    function openStageDialog(gate, section) {
        var dialog = {
            heading: 'Open ' + gate.title + ' for ' + section + '?',
            confirmLabel: 'Open stage',
            tone: 'accent'
        };
        if (gate.key === 'ocean') {
            dialog.message = 'Students marked Present can enter.';
            return dialog;
        }
        var stay = [];
        var enter = [];
        Admin.state.cohort.forEach(function (s) {
            if (s.section !== section || !s.email) {
                return;
            }
            var prev = earlierOpenGate(gate, section);
            var why = prev && s.current_stage === prev.label ? 'Still in the ' + prev.title : stayOutReason(gate, s);
            (why ? stay : enter).push([Admin.studentLabel(s.email), why ? { text: why, tone: 'warn' } : { text: 'Can enter', tone: 'good' }]);
        });
        dialog.message = enter.length + ' can enter. ' + stay.length + ' stay out.';
        var before = earlierOpenGate(gate, section);
        if (before) {
            var still = insideStage(before, section).length;
            dialog.message += still
                ? ' ' + before.title + ' stays open: ' + still + (still === 1 ? ' student is' : ' students are') + ' still inside.'
                : ' ' + before.title + ' closes now, nobody is inside.';
        }
        dialog.table = { columns: ['Student', 'Status'], rows: stay.concat(enter) };
        return dialog;
    }

    async function toggleStage(gate, btn) {
        var section = window.PIASectionNow || '';
        if (!section || window.PIASessionLive || btn.classList.contains('is-working')) {
            return;
        }
        btn.classList.add('is-working');
        btn.disabled = true;
        try {
            Admin.state.gateSelected[gate.key] = [section];
            var opening = !sectionOpen(gate, section);
            // When attendance is still to be locked, that dialog is the only question: accepting it opens the stage.
            var asked = false;
            if (opening && window.PIAAttendanceCheckpoint) {
                var answer = await window.PIAAttendanceCheckpoint(section, gate.title);
                if (!answer) {
                    return;
                }
                asked = answer === 'confirmed';
            }
            if (sectionOpen(gate, section)) {
                await revokeSections(gate.key, null);
            } else if (asked) {
                await grantSections(gate.key, null);
            } else {
                var ok = await Admin.confirmAction(openStageDialog(gate, section));
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

        // The stage before closes by itself once nobody is inside it (a student still inside keeps it open).
        for (var c = 0; c < names.length; c++) {
            var earlier = earlierOpenGate(gate, names[c]);
            if (earlier && !failed.some(function (f) { return f.section === names[c]; }) && !insideStage(earlier, names[c]).length) {
                Admin.state.gateSelected[earlier.key] = [names[c]];
                await revokeSections(earlier.key, null, true);
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
                    return [Admin.studentLabel(item.email), plainReason(item.reason)];
                })
            }
        );
    }

    function plainReason(reason) {
        var text = String(reason || '').trim();
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
                    : 'Close ' + gate.title + ' for ' + names.join(', ') + '?',
                message:
                    (online.length
                        ? 'The experiment ends. Everyone below is signed out on every device. '
                        : inside.length
                          ? inside.length + (inside.length === 1 ? ' student is' : ' students are') + ' inside now. They go back to the Waiting Room. '
                          : 'Nobody is inside right now. ') +
                    'Nothing they submitted is removed.' +
                    (everyone ? '' : ' Other sections keep their access.'),
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
                confirmLabel: online.length ? 'Close Game and sign out all' : 'Close stage'
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
