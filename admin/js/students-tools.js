/* PIA ADMIN CONSOLE -- THE STUDENTS PAGE: SECTION CHIPS, ATTENDANCE, NUMBERS */
(function () {
    'use strict';

    var esc = escapeHTML;

    var REFRESH_MS = 4000;

    var overview = { sections: [], open: [] };
    var profs = [];
    var profOnline = {};
    var holder = {};
    var marks = {};
    var built = false;
    var polling = false;

    function failure(error) {
        var raw = String((error && error.message) || '');
        if (/only an administrator|42501/i.test(raw)) {
            return 'Only an administrator can do this. Sign in as admin.';
        }
        if (/PGRST202|42883|could not find the function/i.test(raw)) {
            return 'The latest database update is not applied yet.';
        }
        var plain = raw.replace(/^PIA:\s*/, '');
        if (window.PIAAdmin && window.PIAAdmin.teacherWords) {
            plain = window.PIAAdmin.teacherWords(plain);
        }
        return plain || 'Something went wrong. Try again.';
    }

    async function call(name, args) {
        var res = await sb.rpc(name, args || {});
        if (res.error) {
            throw res.error;
        }
        return res.data;
    }

    function pageVisible() {
        var panel = $('#view-students');
        return !!panel && !panel.classList.contains('is-hidden') && !document.hidden;
    }

    function chosen() {
        var select = $('#section-filter');
        return select ? select.value : '';
    }

    function scoped() {
        return window.PIAAllSections ? '' : chosen();
    }

    Object.defineProperty(window, 'PIASectionNow', {
        get: function () {
            return chosen();
        },
        configurable: true
    });

    function digitsOf(s) {
        return String(s || '').replace(/\D/g, '');
    }
    function prettyNumber(s) {
        var d = digitsOf(s).slice(0, 11);
        return d;
    }

    function say(message, isError) {
        if (!message) {
            return;
        }
        var admin = window.PIAAdmin;
        if (admin) {
            (isError ? admin.toastErr : admin.toastOk)(isError ? 'Class' : 'Done', message);
        }
    }

    async function saveNumber(email, raw) {
        var d = digitsOf(raw);
        if (d.length !== 11) {
            return { ok: false, message: 'Student number must be 11 digits' };
        }
        try {
            await call('admin_set_student_number', { p_email: email, p_number: d });
            return { ok: true, number: prettyNumber(d) };
        } catch (error) {
            return { ok: false, message: failure(error) };
        }
    }

    function cellHtml(st) {
        if (st.readOnly) {
            return st.number
                ? '<span class="mono">' + esc(prettyNumber(st.number)) + '</span>'
                : '<span class="scope-line">—</span>';
        }
        if (st.editing) {
            return (
                '<div style="display:flex;gap:6px;align-items:center;flex-wrap:wrap">' +
                '<input class="input input-sm mono" type="text" inputmode="numeric" maxlength="14" autocomplete="off" data-ci-number ' +
                'style="width:10rem" value="' +
                esc(st.draft != null ? st.draft : st.number) +
                '" placeholder="11 digits" aria-label="Student number"' +
                (st.msg ? ' aria-invalid="true"' : '') +
                '>' +
                '<button type="button" class="btn btn-primary btn-sm" data-ci-save>Save</button>' +
                '<button type="button" class="btn btn-ghost btn-sm" data-ci-cancel>Cancel</button></div>' +
                (st.msg
                    ? '<p class="field-msg" style="margin:4px 0 0">' + esc(st.msg) + '</p>'
                    : '')
            );
        }
        return st.number
            ? '<span class="mono">' +
                  esc(prettyNumber(st.number)) +
                  '</span> <button type="button" class="btn btn-ghost btn-sm" data-ci-edit aria-label="Edit student number">Edit</button>'
            : '<button type="button" class="btn btn-ghost btn-sm" data-ci-edit>Add number</button>';
    }

    function paintCell(cell) {
        cell.innerHTML = cellHtml(cell._st);
        if (cell._st.editing) {
            var input = $('[data-ci-number]', cell);
            if (input) {
                input.focus();
                input.select();
            }
        }
    }

    async function saveCell(cell) {
        var st = cell._st;
        var input = $('[data-ci-number]', cell);
        var button = $('[data-ci-save]', cell);
        if (button) {
            button.disabled = true;
        }
        var result = await saveNumber(st.email, input ? input.value : '');
        if (result.ok) {
            st.number = result.number;
            st.editing = false;
            st.msg = '';
            st.draft = null;
            if (st.onSaved) {
                st.onSaved();
            }
            paintCell(cell);
            refreshOverview().catch(function () {});
        } else {
            st.msg = result.message;
            st.draft = input ? input.value : '';
            paintCell(cell);
        }
    }

    function bindCell(cell, email, number, options) {
        options = options || {};
        cell._st = {
            email: email,
            number: number || '',
            editing: false,
            msg: '',
            draft: null,
            readOnly: !!options.readOnly,
            onSaved: options.onSaved || null
        };
        if (!cell._bound) {
            cell._bound = true;
            ['click', 'keydown', 'keyup', 'dblclick'].forEach(function (type) {
                cell.addEventListener(type, function (event) {
                    event.stopPropagation();
                });
            });
            cell.addEventListener('click', function (event) {
                if (event.target.closest('[data-ci-edit]')) {
                    cell._st.editing = true;
                    cell._st.msg = '';
                    cell._st.draft = null;
                    paintCell(cell);
                } else if (event.target.closest('[data-ci-cancel]')) {
                    cell._st.editing = false;
                    cell._st.msg = '';
                    paintCell(cell);
                } else if (event.target.closest('[data-ci-save]')) {
                    saveCell(cell);
                }
            });
            cell.addEventListener('keydown', function (event) {
                if (!event.target.matches('[data-ci-number]')) {
                    return;
                }
                if (event.key === 'Enter') {
                    event.preventDefault();
                    saveCell(cell);
                } else if (event.key === 'Escape') {
                    event.preventDefault();
                    cell._st.editing = false;
                    cell._st.msg = '';
                    paintCell(cell);
                }
            });
        }
        paintCell(cell);
    }

    function isOpen(name) {
        return overview.open.some(function (c) {
            return c.section === name;
        });
    }

    function titleHost() {
        var host = $('#section-host');
        if (host) {
            return host;
        }
        var title = $('#view-students .page-title');
        if (!title) {
            return null;
        }
        title.textContent = '';
        var lead = document.createElement('span');
        lead.className = 'sr-only';
        lead.textContent = 'Section ';
        host = document.createElement('div');
        host.id = 'section-host';
        title.appendChild(lead);
        title.appendChild(host);
        return host;
    }

    function updateHostVisibility() {
        var host = $('#section-host');
        if (!host) {
            return;
        }

        var shown = ['students', 'live', 'controls'].some(function (name) {
            var panel = $('#view-' + name);
            return !!panel && !panel.classList.contains('is-hidden');
        });
        host.hidden = !shown;
    }

    function displayName(f) {
        var n = String((f && f.name) || '').trim();
        if (!n || n.indexOf('@') !== -1) {
            n = String(n || (f && f.email) || '').split('@')[0];
        }
        return n || 'Teacher';
    }

    function profsOf(section) {
        var email = holder[section];
        return profs.filter(function (f) {
            return String(f.email).toLowerCase() === email;
        });
    }
    function sectionsOf(email) {
        return Object.keys(holder)
            .filter(function (name) {
                return holder[name] === String(email).toLowerCase();
            })
            .sort();
    }

    function renderChips() {
        var h1 = titleHost();
        if (!h1) {
            return;
        }
        var chips = $('#section-chips');
        if (chips) {
            chips.style.display = 'none';
        }
        var now = chosen();
        var label = window.PIAAllSections ? 'All sections' : now ? now : 'Choose a section';
        var row = function (value, name, count, open) {
            return (
                '<button type="button" role="menuitemradio" class="custom-select-option section-opt' +
                (now === value ? ' is-selected' : '') +
                '" aria-checked="' +
                (now === value) +
                '" data-chip="' +
                esc(value) +
                '"><span>' +
                esc(name) +
                (open ? ' <span class="badge badge-accent">Open</span>' : '') +
                '</span><span class="mono section-opt-count">' +
                count +
                '</span></button>'
            );
        };

        var meta = overview.sections.filter(function (x) {
            return x.section === now;
        })[0];
        var remove = now
            ? '<button type="button" data-section-delete class="custom-select-option section-opt section-opt-danger" ' +
              '>Delete ' +
              esc(now) +
              '</button>'
            : '';

        var menu =
            '<div data-section-menu role="menu" hidden class="custom-select-list section-menu">' +
            overview.sections
                .map(function (x) {
                    return row(x.section, x.section, x.students, isOpen(x.section));
                })
                .join('') +
            '<button type="button" data-section-new class="custom-select-option section-opt section-opt-sep">+ New section</button>' +
            remove +
            '</div>';
        var wasOpen =
            h1.querySelector('[data-section-menu]') &&
            !h1.querySelector('[data-section-menu]').hidden;
        h1.innerHTML =
            '<button type="button" data-section-toggle aria-haspopup="menu" aria-expanded="' +
            !!wasOpen +
            '">' +
            esc(label) +
            '<span class="custom-select-chevron" aria-hidden="true"></span></button>' +
            menu;
        updateHostVisibility();
        if (wasOpen) {
            h1.querySelector('[data-section-menu]').hidden = false;
        }
        renderProfLine();
    }

    function closeProfMenu() {
        var m = $('#prof-menu');
        if (m) {
            m.remove();
        }
    }

    function openProfMenu(anchor) {
        closeProfMenu();
        var section = chosen();
        var current = holder[section] || '';
        var rows = profs
            .slice()
            .sort(function (a, b) {
                return String(a.name).localeCompare(String(b.name));
            })
            .map(function (f) {
                var email = String(f.email).toLowerCase();
                var theirs = sectionsOf(email);
                return (
                    '<button type="button" class="custom-select-option section-opt' +
                    (email === current ? ' is-selected' : '') +
                    '" data-assign="' +
                    esc(email) +
                    '"><span>' +
                    esc(displayName(f)) +
                    '</span><span class="section-opt-count">' +
                    (theirs.length ? esc(theirs.join(', ')) : 'no section') +
                    '</span></button>'
                );
            })
            .join('');
        var menu = document.createElement('div');
        menu.id = 'prof-menu';
        menu.setAttribute('role', 'menu');
        menu.className = 'custom-select-list section-menu';
        menu.innerHTML =
            rows +
            '<button type="button" data-prof-add class="custom-select-option section-opt section-opt-sep">+ Add new teacher</button>' +
            (current
                ? '<button type="button" data-assign="" class="custom-select-option section-opt section-opt-danger">Remove teacher from ' +
                  esc(section) +
                  '</button>'
                : '');
        anchor.parentNode.style.position = 'relative';
        anchor.parentNode.appendChild(menu);
    }

    function initials(name) {
        var w = String(name || '')
            .trim()
            .split(/\s+/)
            .filter(Boolean);
        return ((w[0] || '?')[0] + (w.length > 1 ? w[w.length - 1][0] : '')).toUpperCase();
    }

    function renderProfLine() {
        var el = $('#prof-line');
        if (!el) {
            return;
        }
        if (!el._wired) {
            el._wired = true;
            el.addEventListener('keydown', function (event) {
                var card = event.target.closest('.prof-card[data-prof]');
                if (card && event.target === card && (event.key === 'Enter' || event.key === ' ')) {
                    event.preventDefault();
                    card.click();
                }
            });
            el.addEventListener('click', function (event) {
                var open = event.target.closest('[data-prof]');
                var change = event.target.closest('[data-prof-change]');
                var add = event.target.closest('[data-prof-add]');
                var assign = event.target.closest('[data-assign]');
                if (open && !change && !add) {
                    var email = open.getAttribute('data-prof');
                    var rowEl = Array.prototype.slice
                        .call(document.querySelectorAll('#faculty-tbody [data-faculty]'))
                        .filter(function (r) {
                            return r.getAttribute('data-faculty') === email;
                        })[0];
                    if (rowEl) {
                        rowEl.click();
                    } else {
                        say('Could not open that teacher. Reload the page.', true);
                    }
                } else if (change) {
                    if ($('#prof-menu')) {
                        closeProfMenu();
                    } else {
                        openProfMenu(change);
                    }
                } else if (add) {
                    closeProfMenu();
                    var opener = document.querySelector('[data-modal-open="modal-add-professor"]');
                    var section = chosen();
                    if (opener) {
                        opener.click();
                        setTimeout(function () {
                            var sel = $('#ap-section');
                            if (!sel) {
                                return;
                            }
                            Array.prototype.slice.call(sel.options).forEach(function (o) {
                                if (o.value) {
                                    o.disabled = !!holder[o.value];
                                }
                            });
                            if (section && !holder[section]) {
                                sel.value = section;
                            }
                        }, 60);
                    }
                } else if (assign) {
                    var wanted = assign.getAttribute('data-assign');
                    var target = chosen();
                    closeProfMenu();
                    call('admin_set_section_professor', {
                        p_section: target,
                        p_email: wanted || null
                    })
                        .then(function () {
                            say(wanted ? 'Teacher assigned.' : 'Teacher removed.');
                            return refreshOverview();
                        })
                        .catch(function (error) {
                            say(failure(error), true);
                        });
                }
            });
            document.addEventListener('click', function (event) {
                if (!el.contains(event.target)) {
                    closeProfMenu();
                }
            });
        }
        var section = scoped();
        if (!section) {
            el.innerHTML = '';
            el._sig = '';
            return;
        }
        var list = profsOf(section);
        var who = list.length ? String(list[0].email).toLowerCase() : '';

        var sig =
            section +
            '|' +
            (list.length ? list[0].email + '|' + list[0].name : '') +
            '|' +
            !!profOnline[who];
        if (el._sig === sig) {
            return;
        }
        el._sig = sig;
        closeProfMenu();
        if (!list.length) {
            el.innerHTML =
                '<div class="prof-card is-empty"><p class="prof-card-none">No teacher yet for ' +
                esc(section) +
                '.</p>' +
                '<button type="button" class="btn btn-secondary btn-sm" data-prof-change>Assign teacher</button></div>';
            return;
        }
        var f = list[0];
        var name = displayName(f);
        el.innerHTML =
            '<div class="prof-card is-clickable" data-prof="' +
            esc(f.email) +
            '" tabindex="0"><div class="prof-card-head">' +
            '<span class="prof-card-avatar" aria-hidden="true">' +
            esc(initials(name)) +
            '<span class="avatar-dot' +
            (profOnline[String(f.email).toLowerCase()] ? ' is-online' : '') +
            '" data-presence="' +
            esc(f.email) +
            '" title="' +
            (profOnline[String(f.email).toLowerCase()] ? 'Signed in' : 'Signed out') +
            '"></span></span>' +
            '<div class="prof-card-who"><span class="prof-card-role">Class teacher</span>' +
            '<span class="prof-card-name"><span data-mask>' +
            esc(name) +
            '</span></span>' +
            '</div></div></div>';
    }

    var LAST_KEY = 'pia_students_section';

    function ensureSection() {
        if (chosen() || !overview.sections.length) {
            return;
        }
        var names = overview.sections.map(function (x) {
            return x.section;
        });
        var last = '';
        try {
            last = localStorage.getItem(LAST_KEY) || '';
        } catch (e) {
            last = '';
        }
        var open = overview.open.length ? overview.open[0].section : '';
        var pick = names.indexOf(open) >= 0 ? open : names.indexOf(last) >= 0 ? last : names[0];
        pickSection(pick);
    }

    function pickSection(name) {

        var box = $('#student-search');
        if (window.PIAAllSections && box) {
            box.value = '';
            box.dispatchEvent(new Event('input', { bubbles: true }));
        }
        var select = $('#section-filter');
        if (!name) {
            return;
        }
        try {
            localStorage.setItem(LAST_KEY, name);
        } catch (e) {}
        if (!select || select.value === name) {
            return;
        }
        select.value = name;
        select.dispatchEvent(new Event('change', { bubbles: true }));
        renderChips();
        renderAttendance();
        refreshOverview().catch(function () {});
    }

    function openFor(section) {
        return overview.open.filter(function (c) {
            return c.section === section;
        })[0];
    }

    function renderAttendance() {
        var section = scoped();
        var btn = $('#att-toggle');
        if (btn) {
            btn.hidden = !section;
            var open = !!section && !!openFor(section);
            btn.textContent = open ? 'Close class' : 'Open class';
            btn.setAttribute('data-ci', open ? 'stop' : 'start');
            btn.className = 'btn btn-sm ' + (open ? 'btn-secondary' : 'btn-primary');
        }
        var liveState = $('#class-live-status');
        if (liveState) {
            var isOpen2 = !!section && !!openFor(section);
            liveState.textContent = !section ? 'Choose a section' : isOpen2 ? 'Class is open' : 'Class is closed';
            var dot = $('#class-live-dot');
            if (dot) {
                dot.classList.toggle('is-on', isOpen2);
            }
        }
        paintMarks();
    }

    function markCell(email) {
        var m = marks[email] || null;
        var state = m ? (m.present ? 'present' : 'absent') : 'none';
        var html =
            '<span class="mk-pair" role="group" aria-label="Attendance">' +
            '<button type="button" class="btn btn-sm ' +
            (state === 'present' ? 'btn-primary' : 'btn-secondary') +
            '" data-mk="present" aria-pressed="' +
            (state === 'present') +
            '" aria-label="Present" title="Present">✓</button> ' +
            '<button type="button" class="btn btn-sm ' +
            (state === 'absent' ? 'btn-danger' : 'btn-secondary') +
            '" data-mk="absent" aria-pressed="' +
            (state === 'absent') +
            '" aria-label="Absent" title="Absent">✗</button></span>';
        if (m && m.entered) {
            html += ' <span class="badge badge-accent">In</span>';
        }
        return html;
    }

    function paintMarks() {
        renderStats();
        var section = scoped();
        var on = !!section;
        var live = on && !!openFor(section);
        document.documentElement.classList.toggle('pia-att-on', live);
        var headRow = $('#roster-thead tr');
        var th = headRow && headRow.querySelector('[data-mk-th]');
        if (on && headRow && !th) {
            th = document.createElement('th');
            th.scope = 'col';
            th.setAttribute('data-mk-th', '');
            th.textContent = 'Attendance';
            headRow.insertBefore(th, headRow.children[1] || null);
        } else if (!on && th) {
            th.remove();
        }
        Array.prototype.slice
            .call(document.querySelectorAll('#student-tbody tr[data-student]'))
            .forEach(function (tr) {
                var cell = tr.querySelector('[data-mk-cell]');
                if (!on) {
                    if (cell) {
                        cell.remove();
                    }
                    return;
                }
                if (!cell) {
                    cell = document.createElement('td');
                    cell.setAttribute('data-mk-cell', '');
                    ['click', 'keydown', 'keyup', 'dblclick'].forEach(function (type) {
                        cell.addEventListener(type, function (event) {
                            event.stopPropagation();
                        });
                    });
                    cell.addEventListener('click', function (event) {
                        onMark(event, tr.getAttribute('data-student'));
                    });
                    tr.insertBefore(cell, tr.children[1] || null);
                }
                var html = live
                    ? markCell(String(tr.getAttribute('data-student')).toLowerCase())
                    : '<span class="scope-line">Not started</span>';
                if (cell._html !== html) {
                    cell._html = html;
                    cell.innerHTML = html;
                }
            });
    }

    async function onMark(event, rawEmail) {
        var btn = event.target.closest('[data-mk]');
        if (!btn) {
            return;
        }
        var section = chosen();
        var email = String(rawEmail).toLowerCase();
        var kind = btn.getAttribute('data-mk');
        try {
            var want = kind === 'present';
            var now = marks[email];
            var next = now && now.present === want ? null : want;
            await call('admin_set_attendance', {
                p_section: section,
                p_email: email,
                p_present: next
            });
            if (next === null) {
                delete marks[email];
            } else {
                marks[email] = {
                    present: next,
                    entered: now ? now.entered : false,
                    refused: now ? now.refused : 0
                };
            }
            say('');
        } catch (error) {
            say(failure(error), true);
        }
        renderAttendance();
    }

    async function refreshOverview() {
        var data = await call('admin_checkin_overview');
        overview.sections = (data && data.sections) || [];
        overview.open = (data && data.open) || [];
        try {
            // A section with no students yet still belongs in the list.
            var all = await sb.from('sections').select('name');
            if (!all.error && all.data) {
                var known = {};
                overview.sections.forEach(function (x) {
                    known[String(x.section).toLowerCase()] = true;
                });
                all.data.forEach(function (r) {
                    var name = String(r.name || '').trim();
                    if (name && !known[name.toLowerCase()]) {
                        known[name.toLowerCase()] = true;
                        overview.sections.push({ section: name, students: 0, without_number: 0, ocean_done: 0 });
                    }
                });
                overview.sections.sort(function (a, b) {
                    return String(a.section).localeCompare(String(b.section), undefined, { numeric: true });
                });
            }
        } catch (e) {}
        try {
            var pr = await sb.from('professors').select('name, email, assigned_section');
            profs = pr.error ? profs : pr.data || [];
            var seen = await sb
                .from('profiles')
                .select('email, active_devices')
                .in(
                    'email',
                    profs.map(function (f) {
                        return f.email;
                    })
                );
            if (!seen.error) {
                profOnline = {};
                (seen.data || []).forEach(function (r) {
                    profOnline[String(r.email).toLowerCase()] = (r.active_devices || []).length > 0;
                });
            }
            var map = {};
            var pairs = await sb.rpc('admin_professor_sections');
            if (!pairs.error && pairs.data) {
                pairs.data.forEach(function (r) {
                    map[r.section] = String(r.email).toLowerCase();
                });
            } else {
                profs.forEach(function (f) {
                    if (f.assigned_section) {
                        map[f.assigned_section] = String(f.email).toLowerCase();
                    }
                });
            }
            holder = map;
        } catch (e) {}
        var section = chosen();
        marks = {};
        if (section && openFor(section)) {
            var rows = await call('admin_attendance', { p_section: section });
            (rows || []).forEach(function (r) {
                marks[String(r.email).toLowerCase()] = {
                    present: !!r.present,
                    entered: !!r.entered,
                    refused: Number(r.refused) || 0
                };
            });
        }
        ensureSection();
        renderChips();
        renderAttendance();
    }

    async function act(button, work) {
        button.disabled = true;
        try {
            await work();
            await refreshOverview();
        } catch (error) {
            say(failure(error), true);
        }
        button.disabled = false;
    }

    function setHidden(on) {
        document.documentElement.classList.toggle('pia-hide-details', on);
        var b = $('#hide-details');
        if (b) {
            b.checked = !on;
        }
        try {
            sessionStorage.setItem('pia_hide_details', on ? '1' : '0');
        } catch (e) {}
    }

    function buildHideToggle() {
        if ($('#hide-details')) {
            return;
        }
        var st = document.createElement('style');
        var H = '.pia-hide-details ';
        var masked =
            H +
            '#student-tbody td:first-child .cell-user-text, ' +
            H +
            '#student-tbody td[data-ci-cell], ' +
            H +
            '#drawer-student #drawer-student-name';

        var sel = function (suffix) {
            return masked
                .split(', ')
                .map(function (x) {
                    return x + suffix;
                })
                .join(', ');
        };
        st.textContent =
            '#roster-thead th{background:var(--line-soft)}' +
            '#section-host{position:relative;display:flex;align-items:center;min-width:0}#section-host[hidden]{display:none}' +
            '#section-host [data-section-toggle]{display:inline-flex;align-items:center;gap:8px;padding:6px 14px;border:1px solid var(--accent-line);background:var(--accent-soft);color:var(--accent-text);border-radius:6px;font:inherit;font-weight:600;cursor:pointer;white-space:nowrap}' +
            '#view-students .filter-row .input{height:40px;min-height:40px;box-sizing:border-box}' +
            '#view-students .page-actions .btn{min-height:40px;box-sizing:border-box}' +
            '[data-section-menu] button:hover{background:var(--line-soft)!important}' +
            '#att-toggle{min-width:10rem;text-align:center}' +
            '#roster-thead th[data-mk-th],#student-tbody td[data-mk-cell]{min-width:14rem}' +
            masked +
            '{position:relative;color:transparent!important}' +
            sel(' *') +
            '{visibility:hidden!important}' +
            sel('::after') +
            '{content:"********";position:absolute;inset:0;display:flex;align-items:center;padding:inherit;box-sizing:border-box;color:var(--text);letter-spacing:2px;font-size:14px}' +
            '.pia-section-picked #roster-thead th:nth-child(4),.pia-section-picked #student-tbody td:nth-child(4){display:none}';
        document.head.appendChild(st);
        var bar = $('#stage-tabs') && $('#stage-tabs').parentNode;
        if (!bar) {
            return;
        }
        var label = document.createElement('label');
        label.className = 'show-details';
        label.title = 'Show or hide personal details';
        label.innerHTML =
            '<input type="checkbox" id="hide-details" class="sr-only" checked>' +
            '<svg class="eye eye-on" viewBox="0 0 24 24" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>' +
            '<svg class="eye eye-off" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 3l18 18"/><path d="M10.6 5.1A10.4 10.4 0 0 1 12 5c6.4 0 10 7 10 7a17 17 0 0 1-3.2 4M6.5 6.6C3.6 8.4 2 12 2 12s3.6 7 10 7c1.7 0 3.2-.4 4.5-1"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/></svg>' +
            '<span class="sr-only">Show details</span>';

        var scopeRow = $('#view-students .scope-row');
        var filterRow = bar.parentNode.querySelector('.filter-row');
        var privacyRow = $('#privacy-row');
        if (privacyRow) {
            privacyRow.appendChild(label);
        } else if (scopeRow) {
            scopeRow.appendChild(label);
        } else if (filterRow) {
            filterRow.appendChild(label);
        } else {
            bar.appendChild(label);
        }
        label.firstChild.addEventListener('change', function (e) {
            setHidden(!e.target.checked);
        });
        var toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.id = 'att-toggle';
        toggle.hidden = true;
        toggle.className = 'btn btn-sm btn-primary';
        toggle.textContent = 'Open class';
        var actionsBar = $('#bar-actions');
        if (actionsBar) {
            actionsBar.appendChild(toggle);
        } else {
            ($('#class-live') || bar).appendChild(toggle);
        }
        toggle.addEventListener('click', function () {
            var section = chosen();
            if (!section) {
                return;
            }
            var starting = toggle.getAttribute('data-ci') !== 'stop';
            act(toggle, function () {
                return starting
                    ? call('admin_start_checkin', { p_section: section, p_minutes: 120 })
                    : call('admin_stop_checkin', { p_section: section });
            });
        });
        var was = true;
        try {
            was = sessionStorage.getItem('pia_hide_details') !== '0';
        } catch (e) {}
        setHidden(was);
    }

    function build() {
        if (built) {
            return;
        }
        // keep the teacher's online status in step with the live presence updates
        var applyPresence = window.PIAAdmin && window.PIAAdmin.applyPresence;
        if (applyPresence) {
            window.PIAAdmin.applyPresence = function (email, online) {
                applyPresence(email, online);
                var key = String(email || '').toLowerCase();
                if (key in profOnline && profOnline[key] !== !!online) {
                    profOnline[key] = !!online;
                    renderProfLine();
                }
            };
        }
        buildHideToggle();
        var h1 = titleHost();
        var actions = $('#view-students .page-actions');
        // the eye sits right beside the section title
        var details = $('#view-students .show-details');
        var title = $('#view-students .page-title');
        if (details && title && !title.parentNode.classList.contains('page-title-row')) {
            var row = document.createElement('div');
            row.className = 'page-title-row';
            title.parentNode.insertBefore(row, title);
            row.appendChild(title);
            row.appendChild(details);
        }
        var stages = $('#stage-let');
        var titleRow = $('#view-students .page-title-row');
        if (stages && titleRow && stages.parentNode !== titleRow) {
            titleRow.appendChild(stages);
        }
        if (details && titleRow && titleRow.lastChild !== details) {
            titleRow.appendChild(details);
        }
        var filter = $('#section-filter');
        if (filter) {
            filter.addEventListener('change', function () {
                document.dispatchEvent(
                    new CustomEvent('pia:section-changed', { detail: { section: chosen() } })
                );
            });
        }
        window.addEventListener('hashchange', updateHostVisibility);
        ['students', 'live', 'controls', 'overview', 'mathtask', 'profile', 'settings'].forEach(
            function (name) {
                var panel = $('#view-' + name);
                if (panel) {
                    new MutationObserver(updateHostVisibility).observe(panel, {
                        attributes: true,
                        attributeFilter: ['class']
                    });
                }
            }
        );
        updateHostVisibility();
        var att = $('#attendance-bar');
        if (att) {
            att.style.display = 'none';
        }
        if (!h1) {
            return;
        }
        built = true;

        var closeMenu = function () {
            var m = h1.querySelector('[data-section-menu]');
            if (m) {
                m.hidden = true;
            }
            var t = h1.querySelector('[data-section-toggle]');
            if (t) {
                t.setAttribute('aria-expanded', 'false');
            }
        };
        h1.addEventListener('click', function (event) {
            if (event.target.closest('[data-section-toggle]')) {
                var m = h1.querySelector('[data-section-menu]');
                if (m) {
                    m.hidden = !m.hidden;
                    h1.querySelector('[data-section-toggle]').setAttribute(
                        'aria-expanded',
                        String(!m.hidden)
                    );
                }
                return;
            }
            if (event.target.closest('[data-section-new]')) {
                closeMenu();
                var opener = document.querySelector('[data-modal-open="modal-new-section"]');
                if (opener) {
                    opener.click();
                }
                return;
            }
            if (event.target.closest('[data-section-delete]')) {
                var doomed = chosen();
                var meta = overview.sections.filter(function (x) {
                    return x.section === doomed;
                })[0];
                var kids = meta && meta.students ? meta.students : 0;
                var prof = profsOf(doomed)[0];
                closeMenu();
                window.PIAAdmin.openDeleteSection({
                    name: doomed,
                    students: kids,
                    teacher: prof ? prof.name || prof.email : '',
                    run: function (moveTo) {
                        return call('admin_delete_section', { p_name: doomed, p_move_to: moveTo || null });
                    },
                    done: async function () {
                        var filter = $('#section-filter');
                        if (filter) {
                            filter.value = '';
                        }
                        say(doomed + ' was deleted.');
                        if (window.PIAAdmin && window.PIAAdmin.refreshAll) {
                            window.PIAAdmin.refreshAll();
                        }
                        await refreshOverview();
                    },
                    failed: function (error) {
                        say(failure(error), true);
                        renderChips();
                    }
                });
                return;
            }
            var chip = event.target.closest('[data-chip]');
            if (chip) {
                closeMenu();
                pickSection(chip.getAttribute('data-chip'));
            }
        });
        document.addEventListener('click', function (event) {
            if (!h1.contains(event.target)) {
                closeMenu();
            }
        });
        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape') {
                closeMenu();
            }
        });

        document.addEventListener('pia:students-added', function () {
            refreshOverview().catch(function () {});
        });
    }

    async function decorateRoster() {
        build();
        var picked =
            !!($('#section-filter') && $('#section-filter').value) && !window.PIAAllSections;
        document.documentElement.classList.toggle('pia-section-picked', picked);
        renderChips();
        renderAttendance();
        paintMarks();
        if (!polling && typeof sb !== 'undefined' && sb) {
            polling = true;
            refreshOverview().catch(function (error) {
                say(failure(error), true);
            });
            setInterval(function () {
                if (pageVisible()) {
                    refreshOverview().catch(function () {});
                }
            }, REFRESH_MS);
        }

        var headRow = $('#roster-thead tr');
        if (headRow && !headRow.querySelector('[data-ci-th]')) {
            var th = document.createElement('th');
            th.scope = 'col';
            th.setAttribute('data-ci-th', '');
            th.textContent = 'Student number';
            var mkTh = headRow.querySelector('[data-mk-th]');
            headRow.insertBefore(th, mkTh ? mkTh.nextSibling : headRow.children[1] || null);
        }

        var rows = Array.prototype.slice.call(
            document.querySelectorAll('#student-tbody tr[data-student]')
        );
        var cells = rows.map(function (tr) {
            var cell = tr.querySelector('[data-ci-cell]');
            if (!cell) {
                cell = document.createElement('td');
                cell.setAttribute('data-ci-cell', '');
                cell.innerHTML = '<span class="scope-line">…</span>';
                var mkCell = tr.querySelector('[data-mk-cell]');
                tr.insertBefore(cell, mkCell ? mkCell.nextSibling : tr.children[1] || null);
            }
            return { tr: tr, cell: cell, email: tr.getAttribute('data-student') };
        });
        if (!cells.length || typeof sb === 'undefined' || !sb) {
            return;
        }

        try {
            var data = await call('admin_numbers_for', {
                p_emails: cells.map(function (c) {
                    return c.email;
                })
            });
            var byEmail = {};
            (data || []).forEach(function (r) {
                byEmail[String(r.email).toLowerCase()] = r.number;
            });
            cells.forEach(function (c) {
                if (c.tr.isConnected) {
                    bindCell(c.cell, c.email, byEmail[String(c.email).toLowerCase()], { readOnly: true });
                }
            });
        } catch (error) {
            cells.forEach(function (c) {
                if (c.tr.isConnected) {
                    c.cell.innerHTML =
                        '<span class="scope-line">' + esc(failure(error)) + '</span>';
                }
            });
        }
    }

    // The student number is edited from the participant profile, not from the table.
    async function loadNumber(cell, email) {
        cell.innerHTML = '<span class="scope-line">…</span>';
        try {
            var data = await call('admin_numbers_for', { p_emails: [email] });
            var row = (data || [])[0];
            bindCell(cell, email, row ? row.number : '', { readOnly: true });
        } catch (error) {
            cell.innerHTML = '<span class="scope-line">' + esc(failure(error)) + '</span>';
        }
    }

    function statCard(label, value, note, bar) {
        return (
            '<div class="stat-card"><div class="stat-label">' +
            esc(label) +
            '</div><div class="stat-value">' +
            value +
            '</div><div class="stat-note">' +
            esc(note) +
            '</div>' +
            (bar != null
                ? '<div class="stat-bar"><i style="width:' + Math.max(0, Math.min(100, bar)) + '%"></i></div>'
                : '') +
            '</div>'
        );
    }

    function renderStats() {
        var host = $('#class-stats');
        var sum = window.PIAAdmin && window.PIAAdmin.state && window.PIAAdmin.state.summary;
        if (!host || !sum) {
            return;
        }
        var total = sum.total;
        var pct = total ? Math.round((sum.done / total) * 100) : 0;
        var cards = [
            statCard('OCEAN completion', pct + '<small>%</small>', sum.done + ' of ' + total + ' assessments completed', pct)
        ];
        if (sum.section) {
            var present = 0;
            Object.keys(marks).forEach(function (email) {
                if (marks[email] && marks[email].present) {
                    present += 1;
                }
            });
            cards.push(
                statCard('Present today', present + ' <small>/ ' + total + '</small>', Math.max(0, total - present) + ' students awaiting attendance')
            );
        }
        var html = cards.join('');
        if (host._html !== html) {
            host._html = html;
            host.innerHTML = html;
        }
    }

    document.addEventListener('pia:scope', renderStats);

    // Called from the teacher profile: close it and show the same picker the row used to offer.
    function changeProfessor() {
        var anchor = $('#prof-line .prof-card');
        if (!anchor) {
            return;
        }
        if (window.PIAAdmin) {
            window.PIAAdmin.closeModal('modal-faculty');
        }
        openProfMenu(anchor);
    }

    function holdsSection(email) {
        var section = chosen();
        return !!section && holder[section] === String(email || '').toLowerCase();
    }

    // Called from the teacher profile: the section keeps its students and waits for a new teacher.
    async function removeFromSection() {
        var section = chosen();
        var Admin = window.PIAAdmin;
        if (!section || !Admin) {
            return;
        }
        var ok = await Admin.confirmAction({
            heading: 'Remove the teacher from ' + section + '?',
            message: 'Their account stays. The section has no teacher until you assign one.',
            confirmLabel: 'Remove from section'
        });
        if (!ok) {
            return;
        }
        Admin.closeModal('modal-faculty');
        try {
            await call('admin_set_section_professor', { p_section: section, p_email: null });
            say('Teacher removed from ' + section + '.');
            await refreshOverview();
            if (Admin.loadFaculty) {
                await Admin.loadFaculty();
            }
        } catch (error) {
            say(failure(error), true);
        }
    }

    window.PIACheckin = {
        changeProfessor: changeProfessor,
        holdsSection: holdsSection,
        removeFromSection: removeFromSection,
        loadNumber: loadNumber,
        decorateRoster: decorateRoster,
        saveNumberFor: function (email, number) {
            return saveNumber(email, number);
        },
        numberFor: async function (email) {
            var data = await call('admin_numbers_for', { p_emails: [email] });
            var row = (data || [])[0];
            return row && row.number ? prettyNumber(row.number) : '';
        },
        refresh: function () {
            renderChips();
            renderAttendance();
        }
    };
})();
