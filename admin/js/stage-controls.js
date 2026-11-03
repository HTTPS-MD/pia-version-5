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
        setInterval(function () {
            if (!document.hidden) {
                renderStageSwitches();
            }
        }, 30000);
    }

    function initGates() {
        wireTutoringDialog();
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

        // group the students who could not enter by why, so the reasons read at a glance
        var groups = [];
        skipped.forEach(function (item) {
            var why = plainReason(item.reason);
            var group = groups.filter(function (g) {
                return g.why === why;
            })[0];
            if (!group) {
                group = { why: why, who: [] };
                groups.push(group);
            }
            group.who.push(Admin.whoIs(item.email));
        });
        var parts = [
            granted.length + ' let in · ' + skipped.length + ' not ready'
        ];
        groups.forEach(function (g) {
            var shown = g.who.slice(0, 10).join(', ');
            var more = g.who.length > 10 ? ' and ' + (g.who.length - 10) + ' more' : '';
            parts.push(g.why + ' (' + g.who.length + ')\n' + shown + more);
        });
        failed.forEach(function (f) {
            parts.push('Could not open ' + f.section + '\n' + Admin.teacherWords(f.message));
        });

        Admin.showNotice(
            granted.length
                ? 'Some students are not ready for ' + gate.title
                : 'No one could enter ' + gate.title,
            parts.join('\n\n'),
            granted.length ? 'accent' : 'danger'
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
            heading: everyone
                ? 'Close ' + gate.title + ' for every section?'
                : 'Close ' + gate.title + ' for ' + names.join(', ') + '?',
            message:
                (inside
                    ? inside +
                      ' student' +
                      (inside === 1 ? ' is' : 's are') +
                      ' inside now and will return to the Waiting Room. '
                    : 'Nobody is inside right now. ') +
                'Nothing already submitted is removed.' +
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
