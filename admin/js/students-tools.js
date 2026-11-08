/* PIA ADMIN CONSOLE -- THE STUDENTS PAGE: SECTION CHIPS, START / END, NUMBERS */
(function () {
    'use strict';

    var esc = escapeHTML;

    var REFRESH_MS = 4000;

    var overview = { sections: [], open: [] };
    var profs = [];
    var profOnline = {};
    var holder = {};
    var marks = {};
    var marksSection = null;
    var learnMap = {}; // email -> the latest learning profile of the chosen section (from the database)
    var onlineMap = {}; // email -> is signed in now, for the chosen section (read every refresh)
    var sessionState = 'none'; // none | open | ended | locked, from the database
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

    document.addEventListener('pia:popup-open', function (event) {
        if (event.detail !== 'prof') {
            closeProfMenu();
        }
    });

    function openProfMenu(anchor) {
        closeProfMenu();
        document.dispatchEvent(new CustomEvent('pia:popup-open', { detail: 'prof' }));
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
            (profOnline[String(f.email).toLowerCase()] ? 'Online' : 'Offline') +
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
        renderSession();
        refreshOverview().catch(function () {});
    }

    function openFor(section) {
        return overview.open.filter(function (c) {
            return c.section === section;
        })[0];
    }

    // ---- The bell: students of this section who tried to sign in again ----
    function dismissedMap() {
        try {
            return JSON.parse(localStorage.getItem('pia_bell_dismissed') || '{}') || {};
        } catch (e) {
            return {};
        }
    }
    function bellKey(section, email, n) {
        return section + '|' + email + '|' + n;
    }
    function bellItems() {
        var section = scoped();
        if (!section) {
            return [];
        }
        var gone = dismissedMap();
        var list = [];
        (window.PIAAdmin.state.cohort || []).forEach(function (c) {
            var key = c.email ? String(c.email).toLowerCase() : '';
            var m = marks[key];
            if (c.section === section && m && m.refused > 0 && !gone[bellKey(section, key, m.refused)]) {
                list.push({
                    email: key,
                    initials: window.PIAAdmin.initialsOf(c.full_name, c.email),
                    n: m.refused
                });
            }
        });
        return list;
    }
    function renderBell() {
        var box = $('#att-bell-box');
        if (!box) {
            return;
        }
        var section = scoped();
        box.classList.toggle('is-hidden', !section);
        box.hidden = !section;
        var items = bellItems();
        var count = $('#att-bell-count');
        if (count) {
            count.textContent = String(items.length);
            count.classList.toggle('is-hidden', !items.length);
        }
        // phone: the bell lives in the profile menu (a number on the profile picture and a list inside the menu)
        var uBadge = $('#user-avatar-badge');
        var uCount = $('#user-notif-count');
        var uBtn = $('#user-notif-btn');
        if (uBadge) {
            uBadge.textContent = String(items.length);
            uBadge.classList.toggle('is-hidden', !items.length);
        }
        if (uCount) {
            uCount.textContent = String(items.length);
            uCount.classList.toggle('is-hidden', !items.length);
        }
        if (uBtn) {
            uBtn.classList.toggle('is-hidden', !section);
        }
        var btn = $('#att-bell');
        if (btn) {
            btn.setAttribute(
                'aria-label',
                items.length ? items.length + ' student(s) tried to sign in again' : 'No one is waiting to be let back in'
            );
        }
        var menu = $('#att-bell-menu');
        if (!menu) {
            return;
        }
        var sig =
            section +
            '|' +
            items
                .map(function (i) {
                    return i.email + ':' + i.n;
                })
                .join(',');
        if (menu._sig === sig) {
            return;
        }
        menu._sig = sig;
        var bellIcon =
            '<svg viewBox="0 0 24 24" width="26" height="26" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/></svg>';
        menu.innerHTML =
            (items.length
                ? '<div class="custom-select-option section-opt bell-head">Tried to sign in again · ' + esc(section) + '</div>'
                : '') +
            (items.length
                ? items
                      .map(function (i) {
                          return (
                              '<div class="custom-select-option section-opt bell-item" data-email="' + esc(i.email) + '" data-n="' + i.n + '">' +
                              '<span class="bell-av">' + esc(i.initials) + '</span>' +
                              '<span class="bell-text">tried ×' + i.n + '</span>' +
                              '<button type="button" class="btn btn-sm btn-primary" data-bell-lbi>Let back in</button>' +
                              '<button type="button" class="btn btn-sm btn-secondary" data-bell-dismiss>Dismiss</button>' +
                              '</div>'
                          );
                      })
                      .join('')
                : '<div class="custom-select-option section-opt bell-empty">' + bellIcon + '<span>No new notifications</span></div>');
        var mirror = $('#user-notif-list');
        if (mirror) {
            mirror.innerHTML = menu.innerHTML;
        }
    }
    // Let back in goes straight through: no question afterwards.
    async function bellLetBackIn(email) {
        await letBackIn(email);
    }
    function bellDismiss(email, n) {
        var section = scoped();
        var map = dismissedMap();
        map[bellKey(section, email, n)] = true;
        try {
            localStorage.setItem('pia_bell_dismissed', JSON.stringify(map));
        } catch (e) {}
        renderBell();
    }

    // A menu that opens under a button moves to <body> and sits right under the button, right edges lined up.
    // On <body> its frosted-glass blur can see the whole page (inside a glass card it could not).
    function placeFloating(button, menu) {
        if (menu.parentNode !== document.body) {
            document.body.appendChild(menu);
        }
        var r = button.getBoundingClientRect();
        menu.style.top = Math.round(r.bottom + 8) + 'px';
        menu.style.right = Math.max(8, Math.round(window.innerWidth - r.right)) + 'px';
        menu.style.left = 'auto';
    }

    // A button that opens a floating menu. One popup at a time: opening any popup announces itself
    // (event pia:popup-open) and every other popup closes. Also closes on an outside click, Esc, scroll or resize.
    // Returns set(open).
    function floatingMenu(id, button, menu, box) {
        function set(open) {
            if (open) {
                document.dispatchEvent(new CustomEvent('pia:popup-open', { detail: id }));
                placeFloating(button, menu);
            }
            menu.hidden = !open;
            button.setAttribute('aria-expanded', open ? 'true' : 'false');
        }
        function close() {
            set(false);
        }
        button.addEventListener('click', function (event) {
            event.stopPropagation();
            set(menu.hidden);
        });
        document.addEventListener('pia:popup-open', function (event) {
            if (event.detail !== id) {
                close();
            }
        });
        document.addEventListener('click', function (event) {
            if (!box.contains(event.target) && !menu.contains(event.target)) {
                close();
            }
        });
        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape') {
                close();
            }
        });
        window.addEventListener('resize', close);
        document.addEventListener('scroll', close, true);
        return set;
    }

    // The Archived button shows once a section is chosen.
    function updateArchivedButton() {
        var removed = $('#att-removed');
        if (removed) {
            var on = !!scoped();
            removed.hidden = !on;
            removed.classList.toggle('is-hidden', !on);
        }
    }

    function renderSession() {
        var section = scoped();
        var btn = $('#att-toggle');
        var open = !!section && !!openFor(section);
        // Privacy Mode hides names and numbers: with no student and no teacher in the section there is nothing to hide.
        var privacyBox = document.querySelector('label.privacy-mode');
        if (privacyBox) {
            var info = null;
            overview.sections.forEach(function (x) {
                if (x.section === section) {
                    info = x;
                }
            });
            var nothing = !!section && !!info && Number(info.students) === 0 && !holder[section];
            privacyBox.classList.toggle('is-hidden', nothing);
        }
        var ended = !!section && !open && sessionState === 'locked';
        if (btn) {
            // A section with no students has nobody to let in: no Start button.
            var meta = null;
            overview.sections.forEach(function (x) {
                if (x.section === section) {
                    meta = x;
                }
            });
            var noStudents = !!meta && Number(meta.students) === 0 && !open;
            var hideBtn = !section || noStudents;
            btn.hidden = hideBtn;
            updateArchivedButton();
            // The button says which section it acts on: it sits in the top bar, which is the same on every tab.
            var over = ended && window.PIAGameClosed === section && !!window.PIAStagesFinished; // the experiment is over
            // After Close gate, once every stage is closed, the same button ends the experiment.
            var canEnd = ended && !over && !window.PIAStagesOpen;
            var waitStages = ended && !over && !!window.PIAStagesOpen;
            btn.textContent = over ? 'Experiment ended' : ended ? (waitStages ? 'Gate closed' : 'End experiment') : open ? 'Close gate' : 'Open gate';
            btn.setAttribute('data-ci', canEnd ? 'end' : ended ? 'locked' : open ? 'stop' : 'start');
            // .btn sets its own display, which beats [hidden]: the is-hidden class does the hiding.
            btn.className =
                'btn ' + (open || ended ? 'btn-secondary' : 'btn-primary') + (hideBtn ? ' is-hidden' : '');
            btn.disabled = ended && !canEnd;
            btn.title = over
                ? 'The experiment ended for this section (Game closed). The stages stay hidden until tomorrow.'
                : canEnd
                  ? 'End experiment: the stages are closed. Everyone online is signed out and the stages stay hidden until tomorrow.'
                  : ended
                  ? 'The gate was closed today. Close every stage, then you can end the experiment.'
                  : open
                    ? 'Students are entering. Press Close gate to stop letting students in and start the experiment.'
                    : 'Open gate: let the students in';
        }
        // The live count at the top: Entered x of n (only once the session has started).
        var chip = $('#att-count');
        if (chip) {
            var total = 0;
            var entered = 0;
            if (section && (open || ended)) {
                (window.PIAAdmin.state.cohort || []).forEach(function (c) {
                    if (c.section === section && c.email) {
                        total += 1;
                        if (marks[String(c.email).toLowerCase()] && marks[String(c.email).toLowerCase()].entered) {
                            entered += 1;
                        }
                    }
                });
            }
            chip.textContent = 'Entered ' + entered + ' of ' + total;
            // only while the gate is open: once it is closed the count is no longer needed
            chip.classList.toggle('is-hidden', !(section && open));
        }
        window.PIASessionLive = open;
        window.PIASessionState = section ? sessionState : '';
        if (window.PIAAdmin && window.PIAAdmin.renderStageSwitches) {
            window.PIAAdmin.renderStageSwitches();
        }
        var liveState = $('#class-live-status');
        if (liveState) {
            liveState.textContent = !section ? 'Choose a section' : open ? 'Session open' : ended ? 'Session ended' : 'Not started';
            var dot = $('#class-live-dot');
            if (dot) {
                dot.classList.toggle('is-on', open);
            }
        }
        renderBell();
        paintMarks();
    }

    // One cell: Entered or Not in yet (greyed by CSS while the student is offline), and a count of refused second tries.
    function participationCell(m) {
        var inside = !!m && m.entered;
        var html = '<span class="att-state' + (inside ? ' is-in' : '') + '">' + (inside ? 'Entered' : 'Not in yet') + '</span>';
        if (m && m.refused > 0) {
            html +=
                '<span class="att-meta"><span class="att-blocked" title="Tried to sign in again and was refused. Let back in is in the bell.">Tried again ×' +
                m.refused +
                '</span></span>';
        }
        return html;
    }

    function paintMarks() {
        var section = scoped();
        var on = !!section;
        var started = on && (!!openFor(section) || sessionState === 'locked' || sessionState === 'ended');
        var headRow = $('#roster-thead tr');
        var th = headRow && headRow.querySelector('[data-mk-th]');
        if (on && headRow && !th) {
            th = document.createElement('th');
            th.scope = 'col';
            th.setAttribute('data-mk-th', '');
            th.textContent = 'Participation';
            headRow.insertBefore(th, headRow.children[1] || null);
        } else if (!on && th) {
            th.remove();
        }
        var lpTh = headRow && headRow.querySelector('[data-lp-th]');
        if (on && headRow && !lpTh) {
            lpTh = document.createElement('th');
            lpTh.scope = 'col';
            lpTh.setAttribute('data-lp-th', '');
            lpTh.textContent = 'Profile';
            headRow.appendChild(lpTh);
        } else if (!on && lpTh) {
            lpTh.remove();
        }
        Array.prototype.slice
            .call(document.querySelectorAll('#student-tbody tr[data-student]'))
            .forEach(function (tr) {
                var lpCell = tr.querySelector('[data-lp-cell]');
                if (!on) {
                    if (lpCell) {
                        lpCell.remove();
                    }
                } else {
                    if (!lpCell) {
                        lpCell = document.createElement('td');
                        lpCell.setAttribute('data-lp-cell', '');
                        tr.appendChild(lpCell);
                    }
                    var lp = learnMap[String(tr.getAttribute('data-student')).toLowerCase()];
                    var lpHtml = lp
                        ? '<span class="lp-tag is-' + esc(lp) + '">' + esc(lp.charAt(0).toUpperCase() + lp.slice(1)) + '</span>'
                        : '<span class="att-result is-none">—</span>';
                    if (lpCell._html !== lpHtml) {
                        lpCell._html = lpHtml;
                        lpCell.innerHTML = lpHtml;
                    }
                }
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
                    tr.insertBefore(cell, tr.children[1] || null);
                }
                var key = String(tr.getAttribute('data-student')).toLowerCase();
                var html = started ? participationCell(marks[key]) : '<span class="att-result is-none">—</span>';
                if (cell._html !== html) {
                    cell._html = html;
                    cell.innerHTML = html;
                }
            });
    }

    async function letBackIn(rawEmail) {
        var section = chosen();
        var email = String(rawEmail).toLowerCase();
        try {
            await call('admin_let_back_in', { p_section: section, p_email: email });
            if (marks[email]) {
                marks[email].entered = false;
                marks[email].refused = 0;
            }
            say('');
        } catch (error) {
            say(failure(error), true);
        }
        renderSession();
        refreshOverview().catch(function () {});
    }

    // The section's students who are signed in on any device right now (throws when the lookup fails).
    async function onlineIn(section) {
        var cohort = (window.PIAAdmin.state.cohort || []).filter(function (s) {
            return s.section === section && s.email;
        });
        if (!cohort.length) {
            return [];
        }
        var res = await sb
            .from('profiles')
            .select('email, active_devices')
            .in(
                'email',
                cohort.map(function (s) {
                    return s.email;
                })
            );
        if (res.error) {
            throw res.error;
        }
        return (res.data || [])
            .filter(function (r) {
                return (r.active_devices || []).length > 0;
            })
            .map(function (r) {
                return String(r.email).toLowerCase();
            });
    }

    // Ends these students' logins on every device and says so.
    async function signOutEmails(online) {
        var failed = 0;
        await Promise.all(
            online.map(function (e) {
                return call('admin_revoke_sessions', { p_email: e }).catch(function () {
                    failed += 1;
                });
            })
        );
        if (failed) {
            say(failed + ' of ' + online.length + ' could not be signed out. Try again.', true);
        } else if (online.length && window.PIAAdmin.toastOk) {
            window.PIAAdmin.toastOk('Signed out', online.length + (online.length === 1 ? ' student was' : ' students were') + ' signed out.');
        }
        refreshOverview().catch(function () {});
    }
    window.PIASignOut = { online: onlineIn, signOut: signOutEmails };


    // Close gate: the students who have not entered are listed, and the admin chooses to close, or to close and open OCEAN.
    // Returns true (closed), 'ocean' (closed and OCEAN is opening) or false (cancelled).
    // End experiment: the stages are closed, so this writes the same "Game closed" mark the Game switch writes.
    async function endExperiment(section, btn) {
        var admin = window.PIAAdmin;
        var online = [];
        if (window.PIASignOut) {
            online = await window.PIASignOut.online(section).catch(function () {
                return [];
            });
        }
        var ok = await admin.confirmAction({
            heading: 'End experiment for ' + section + '?',
            message:
                (online.length ? 'Everyone below is signed out. ' : '') + 'The stages stay hidden until tomorrow.',
            table: online.length
                ? {
                      columns: ['Student', 'Now'],
                      rows: online.map(function (e) {
                          return [admin.studentLabel(e), { text: 'Online · will be signed out', tone: 'warn' }];
                      })
                  }
                : null,
            confirmLabel: 'End experiment'
        });
        if (!ok) {
            return;
        }
        btn.disabled = true;
        try {
            await call('admin_end_experiment', { p_section: section });
            if (online.length && window.PIASignOut) {
                window.PIASignOut.signOut(online);
            }
            window.PIAGameClosed = section;
            await refreshOverview();
            if (admin.refreshAll) {
                admin.refreshAll();
            }
        } catch (error) {
            say(failure(error), true);
        }
    }

    async function endDialog(section) {
        var rows = [];
        try {
            rows = (await call('admin_attendance', { p_section: section })) || [];
        } catch (e) {
            say(failure(e), true);
            return false;
        }
        var admin = window.PIAAdmin;
        var inside = {};
        rows.forEach(function (r) {
            inside[String(r.email).toLowerCase()] = !!r.entered;
        });
        var emails = (admin.state.cohort || [])
            .filter(function (c) {
                return c.section === section && c.email;
            })
            .map(function (c) {
                return String(c.email).toLowerCase();
            });
        var notIn = emails.filter(function (e) {
            return !inside[e];
        });
        var preview = admin.previewStage ? await admin.previewStage('ocean', section) : null;
        var canOpen = !!preview && !preview.blocked && !admin.stageIsOpen('ocean', section);
        var answer = await admin.confirmAction({
            heading: 'Close the gate?',
            message: notIn.length
                ? emails.length - notIn.length + ' of ' + emails.length + ' entered. The rest cannot enter after this.'
                : 'Everyone entered.',
            table: {
                columns: ['Student', 'Status'],
                rows: notIn.map(function (e) {
                    return [admin.studentLabel(e), { text: 'Not in yet', tone: 'warn' }];
                })
            },
            confirmLabel: canOpen ? 'Close gate and open OCEAN' : 'Close gate',
            tone: 'accent'
        });
        if (!answer) {
            return false;
        }
        return canOpen && answer === true ? 'ocean' : true;
    }
    // The day's marks for a section: [{ email, present, entered }] (null if they cannot be read).
    window.PIASessionRows = function (section) {
        return call('admin_attendance', { p_section: section }).catch(function () {
            return null;
        });
    };

    // The class accuracy of each topic for the chosen section (the same numbers the teacher gets after the Game is closed).
    var topicsAt = 0;
    var topicsSection = null;
    async function paintTopicBoxes(section) {
        var box = $('#a-topic-boxes');
        if (!box) {
            return;
        }
        if (!section) {
            box.classList.add('is-hidden');
            return;
        }
        var rows;
        try {
            rows = await call('admin_topic_accuracy', { p_section: section });
        } catch (e) {
            return;
        }
        if (section !== chosen()) {
            return;
        }
        [1, 2, 3].forEach(function (t) {
            var found = (rows || []).filter(function (x) {
                return Number(x.topic) === t;
            })[0];
            var value = found && found.accuracy !== null && found.accuracy !== undefined ? Number(found.accuracy) : null;
            $('#a-topic-' + t).textContent = value === null || !isFinite(value) ? '—' : value + '%';
            $('#a-topic-' + t + '-note').textContent = found
                ? 'class accuracy · ' + found.reached + ' of ' + found.total + (Number(found.total) === 1 ? ' student' : ' students') + ' answered'
                : 'class accuracy';
        });
        box.classList.remove('is-hidden');
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
        if (section !== marksSection) {
            marks = {};
            marksSection = section;
            sessionState = 'none';
            learnMap = {};
            onlineMap = {};
        }
        if (section) {
            // The state of the newest record: none, open, ended or locked (a stage was opened).
            try {
                sessionState = await call('admin_attendance_status', { p_section: section });
            } catch (e) {
                sessionState = openFor(section) ? 'open' : Object.keys(marks).length ? 'ended' : 'none';
            }
            // Who is signed in now (the Sign out everyone button shows only while someone is).
            try {
                var emails = (window.PIAAdmin.state.cohort || [])
                    .filter(function (c) {
                        return c.section === section && c.email;
                    })
                    .map(function (c) {
                        return c.email;
                    });
                if (emails.length) {
                    var pres = await sb.from('profiles').select('email, active_devices').in('email', emails);
                    if (!pres.error) {
                        onlineMap = {};
                        (pres.data || []).forEach(function (r) {
                            onlineMap[String(r.email).toLowerCase()] = (r.active_devices || []).length > 0;
                        });
                    }
                }
            } catch (e) {}
            // Has the Game been closed for this section? (the experiment is over: the stage controls step aside)
            try {
                var closedNow = await call('admin_game_closed', { p_section: section });
                window.PIAGameClosed = closedNow ? section : '';
            } catch (e) {}
            // The latest learning profile the decision tree gave each student of the section.
            try {
                var lps = await call('admin_learning_profiles', { p_section: section });
                learnMap = {};
                (lps || []).forEach(function (r) {
                    learnMap[String(r.email).toLowerCase()] = String(r.profile);
                });
            } catch (e) {}
            // Also read it after the session ended, so the record stays on screen.
            try {
                var rows = await call('admin_attendance', { p_section: section });
                if (rows && rows.length) {
                    marks = {};
                    rows.forEach(function (r) {
                        marks[String(r.email).toLowerCase()] = {
                            present: !!r.present,
                            entered: !!r.entered,
                            refused: Number(r.refused) || 0
                        };
                    });
                }
            } catch (e) {
                if (openFor(section)) {
                    throw e;
                }
            }
        }
        ensureSection();
        renderChips();
        renderSession();
        // heavier than the rest: once on a new section, then every 30 seconds
        if (section !== topicsSection || Date.now() - topicsAt > 30000) {
            topicsSection = section;
            topicsAt = Date.now();
            paintTopicBoxes(section);
        }
    }

    function setHidden(on) {
        document.documentElement.classList.toggle('pia-hide-details', on);
        var b = $('#hide-details');
        if (b) {
            b.checked = on;
            var track = b.parentNode.querySelector('.stage-switch');
            if (track) {
                track.classList.toggle('is-on', on);
            }
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
            '#roster-thead th[data-mk-th],#student-tbody td[data-mk-cell]{min-width:9rem}' +
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
        label.className = 'show-details privacy-mode';
        label.title = 'Hides the students’ names and numbers on your screen only';
        label.innerHTML =
            '<input type="checkbox" id="hide-details" class="sr-only" role="switch">' +
            '<span class="stage-switch" aria-hidden="true"></span>' +
            '<span class="privacy-mode-label">Privacy Mode</span>';

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
            setHidden(e.target.checked);
        });
        var toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.id = 'att-toggle';
        toggle.hidden = true;
        toggle.className = 'btn btn-primary';
        toggle.textContent = 'Start';
        var countChip = document.createElement('span');
        countChip.id = 'att-count';
        countChip.className = 'att-count is-hidden';
        var actionsBar = $('#bar-actions');
        if (actionsBar) {
            actionsBar.appendChild(countChip);
        }
        // Start / End sits beside Privacy Mode (moved there by build()).
        if (actionsBar) {
            actionsBar.appendChild(toggle);
        }
        // The bell: students who tried to sign in again.
        var bellBox = document.createElement('div');
        bellBox.className = 'bar-bell is-hidden';
        bellBox.id = 'att-bell-box';
        bellBox.hidden = true;
        bellBox.innerHTML =
            '<button type="button" class="bar-bell-btn" id="att-bell" aria-haspopup="menu" aria-expanded="false" aria-label="No one is waiting to be let back in" title="Students who tried to sign in again">' +
            '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/></svg>' +
            '<span class="bell-count is-hidden" id="att-bell-count"></span></button>' +
            '<div class="custom-select-list section-menu bar-bell-menu" id="att-bell-menu" role="menu" hidden></div>';
        // The bell sits in the top bar, between the theme switch and the profile, so it is seen on every tab.
        var themeBtn = $('#theme-toggle');
        if (themeBtn && themeBtn.parentNode) {
            themeBtn.parentNode.insertBefore(bellBox, themeBtn.nextSibling);
        } else {
            toggle.parentNode.appendChild(bellBox);
        }
        var bellMenu = $('#att-bell-menu');
        var setBell = floatingMenu('bell', $('#att-bell'), bellMenu, bellBox);
        async function onBellClick(event) {
            var item = event.target.closest('.bell-item');
            if (!item) {
                return;
            }
            var email = item.getAttribute('data-email');
            if (event.target.closest('[data-bell-dismiss]')) {
                bellDismiss(email, Number(item.getAttribute('data-n')));
            } else if (event.target.closest('[data-bell-lbi]')) {
                setBell(false);
                await bellLetBackIn(email);
            }
        }
        bellMenu.addEventListener('click', onBellClick);
        var userNotif = $('#user-notif-list');
        if (userNotif) {
            userNotif.addEventListener('click', onBellClick);
        }
        var removedItem = $('#att-removed');
        if (removedItem) {
            removedItem.addEventListener('click', function () {
                showRemoved();
            });
        }
        var removedBack = $('#removed-addback');
        if (removedBack) {
            removedBack.addEventListener('click', addBackPicked);
        }
        var removedDel = $('#removed-delete');
        if (removedDel) {
            removedDel.addEventListener('click', deletePicked);
        }
        toggle.addEventListener('click', async function () {
            var section = chosen();
            if (!section) {
                return;
            }
            if (toggle.getAttribute('data-ci') === 'locked') {
                return;
            }
            if (toggle.getAttribute('data-ci') === 'end') {
                await endExperiment(section, toggle);
                return;
            }
            var starting = toggle.getAttribute('data-ci') !== 'stop';
            var next = true;
            if (!starting) {
                next = await endDialog(section);
                if (!next) {
                    return;
                }
            }
            toggle.disabled = true;
            try {
                await call(starting ? 'admin_start_checkin' : 'admin_stop_checkin', starting ? { p_section: section, p_minutes: 120 } : { p_section: section });
                await refreshOverview();
                if (next === 'ocean') {
                    await window.PIAAdmin.openStageNow('ocean', section);
                }
            } catch (error) {
                say(failure(error), true);
            }
            toggle.disabled = false;
        });
        var tabChoice = null;
        try {
            tabChoice = sessionStorage.getItem('pia_hide_details');
        } catch (e) {}
        if (tabChoice === null) {
            // First load of this sign-in: hidden until the account setting arrives, then follow it.
            setHidden(true);
            if (window.PIAAdmin && window.PIAAdmin.loadPrivacyDefault) {
                window.PIAAdmin.loadPrivacyDefault().then(function (on) {
                    setHidden(on);
                });
            }
        } else {
            setHidden(tabChoice !== '0');
        }
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
        // Open gate / Close gate: right beside Privacy Mode, on its left.
        var startEnd = $('#att-toggle');
        if (startEnd && titleRow && details) {
            // the live count (Entered x of n) sits right before the gate button
            var countChip = $('#att-count');
            if (countChip) {
                titleRow.insertBefore(countChip, details);
            }
            titleRow.insertBefore(startEnd, details);
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
        document.addEventListener('pia:popup-open', function (event) {
            if (event.detail !== 'section') {
                closeMenu();
            }
        });
        h1.addEventListener('click', function (event) {
            if (event.target.closest('[data-section-toggle]')) {
                var m = h1.querySelector('[data-section-menu]');
                if (m) {
                    m.hidden = !m.hidden;
                    if (!m.hidden) {
                        document.dispatchEvent(new CustomEvent('pia:popup-open', { detail: 'section' }));
                    }
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
        renderSession();
        paintMarks();
        if (!polling && typeof sb !== 'undefined' && sb) {
            polling = true;
            refreshOverview().catch(function (error) {
                say(failure(error), true);
            });
            setInterval(function () {
                if (!document.hidden) {
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

    function holdsSection(email) {
        var section = chosen();
        return !!section && holder[section] === String(email || '').toLowerCase();
    }

    // Called from the teacher profile: the section keeps its students and waits for a new teacher.
    async function removeFromSection(options) {
        var section = chosen();
        var Admin = window.PIAAdmin;
        if (!section || !Admin) {
            return;
        }
        // the Remove Teacher window already asked, so it asks no second time
        var ok =
            options && options.confirmed
                ? true
                : await Admin.confirmAction({
                      heading: 'Remove the teacher from ' + section + '?',
                      message: 'The section has no teacher until you assign one.',
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

    // ---- Remove from this session / Add back ----
    // A removed student keeps the account and every answer; the roster, the count, the door and the teacher stop counting them.
    async function askReason(email, options) {
        var Admin = window.PIAAdmin;
        // the Remove Student window already asked, so it asks no second time
        var ok =
            options && options.confirmed
                ? true
                : await Admin.confirmAction({
                      heading: 'Archive ' + Admin.studentLabel(email) + '?',
                      message: 'They will not be counted and cannot enter.',
                      confirmLabel: 'Archive',
                      tone: 'accent'
                  });
        if (!ok) {
            return;
        }
        try {
            await call('admin_remove_from_session', { p_email: email });
            say('Archived.');
            // A student who is signed in is signed out: they are no longer part of the session. That, the roster
            // and the counts all go at the same time instead of one after another.
            await Promise.all([
                onlineIn(chosen())
                    .then(function (list) {
                        return signOutEmails(
                            list.filter(function (e) {
                                return e === String(email).toLowerCase();
                            })
                        );
                    })
                    .catch(function () {}),
                Admin.refreshAll(),
                refreshOverview()
            ]);
        } catch (error) {
            say(failure(error), true);
        }
    }

    var picked = {}; // email -> true: the students ticked in Archived

    function paintPicked() {
        var emails = Object.keys(picked);
        var rows = document.querySelectorAll('#removed-table [data-row]');
        var count = $('#removed-count');
        if (count) {
            count.textContent = !rows.length ? '' : emails.length ? emails.length + ' selected' : '';
        }
        // Delete waits until at least one student is ticked.
        var del = $('#removed-delete');
        if (del) {
            del.disabled = !emails.length;
        }
        // Add back waits until at least one student is ticked, like Delete
        var back = $('#removed-addback');
        if (back) {
            back.disabled = !emails.length;
        }
        var all = $('#removed-all');
        if (all) {
            all.checked = !!rows.length && emails.length === rows.length;
            all.indeterminate = emails.length > 0 && emails.length < rows.length;
        }
    }

    async function showRemoved() {
        var Admin = window.PIAAdmin;
        picked = {};
        var section = chosen();
        var host = $('#removed-table');
        host.textContent = 'Loading…';
        paintPicked();
        Admin.openModal('modal-removed');
        var res = await sb
            .from('profiles')
            .select('email, full_name, removed_at')
            .eq('section', section)
            .not('removed_at', 'is', null)
            .order('removed_at', { ascending: false });
        if (res.error) {
            host.textContent = failure(res.error);
            return -1;
        }
        var rows = res.data || [];
        if (!rows.length) {
            host.innerHTML = '<p class="muted">Nobody is archived in ' + esc(section) + '.</p>';
            paintPicked();
            return 0;
        }
        // The list shows at once; the student numbers fill in when they arrive (and are never asked for under
        // Privacy Mode, where they are masked like everywhere else).
        var numbers = {};
        var hidden = document.documentElement.classList.contains('pia-hide-details');
        host.innerHTML =
            '<div class="table-wrap"><table class="table"><thead><tr>' +
            '<th scope="col" class="removed-check"><input type="checkbox" id="removed-all" aria-label="Select all"></th>' +
            '<th scope="col">Student</th><th scope="col">Student number</th></tr></thead><tbody>' +
            rows
                .map(function (r) {
                    var who = document.documentElement.classList.contains('pia-hide-details')
                        ? Admin.initialsOf(r.full_name, r.email)
                        : r.full_name;
                    return (
                        '<tr data-row data-email="' + esc(r.email) + '" data-who="' + esc(who) + '">' +
                        '<td class="removed-check"><input type="checkbox" data-pick aria-label="Select ' + esc(who) + '"></td>' +
                        '<td>' + esc(who) + '</td>' +
                        '<td class="mono" data-number-for="' + esc(r.email) + '">' + esc(hidden ? '********' : '…') + '</td>' +
                        '</tr>'
                    );
                })
                .join('') +
            '</tbody></table></div>';
        paintPicked();
        if (!hidden) {
            call('admin_numbers_for', {
                p_emails: rows.map(function (r) {
                    return r.email;
                })
            }).then(
                function (list) {
                    (list || []).forEach(function (n) {
                        numbers[String(n.email).toLowerCase()] = prettyNumber(n.number);
                    });
                    Array.prototype.forEach.call(host.querySelectorAll('[data-number-for]'), function (td) {
                        td.textContent = numbers[String(td.getAttribute('data-number-for')).toLowerCase()] || '—';
                    });
                },
                function () {
                    Array.prototype.forEach.call(host.querySelectorAll('[data-number-for]'), function (td) {
                        td.textContent = '—';
                    });
                }
            );
        }
        host.onchange = function (event) {
            var all = event.target.closest('#removed-all');
            if (all) {
                picked = {};
                Array.prototype.forEach.call(host.querySelectorAll('[data-row]'), function (tr) {
                    tr.querySelector('[data-pick]').checked = all.checked;
                    if (all.checked) {
                        picked[tr.getAttribute('data-email')] = true;
                    }
                });
            } else if (event.target.matches('[data-pick]')) {
                var tr = event.target.closest('[data-row]');
                if (event.target.checked) {
                    picked[tr.getAttribute('data-email')] = true;
                } else {
                    delete picked[tr.getAttribute('data-email')];
                }
            }
            paintPicked();
        };
        return rows.length;
    }

    // Takes the given students out of the Archived list without asking the server again. When the last one
    // is gone there is nothing left to show: the dialog closes.
    function dropArchivedRows(emails) {
        emails.forEach(function (email) {
            delete picked[email];
            Array.prototype.forEach.call(document.querySelectorAll('#removed-table [data-row]'), function (tr) {
                if (tr.getAttribute('data-email') === email) {
                    tr.remove();
                }
            });
        });
        paintPicked();
        if (!document.querySelector('#removed-table [data-row]')) {
            window.PIAAdmin.closeModal('modal-removed');
        }
    }

    // The roster and the session counts follow along without keeping the dialog waiting.
    function refreshBehind() {
        Promise.all([window.PIAAdmin.refreshAll(), refreshOverview()]).catch(function () {});
    }

    function pickedRows() {
        return Array.prototype.filter.call(document.querySelectorAll('#removed-table [data-row]'), function (tr) {
            return picked[tr.getAttribute('data-email')];
        });
    }

    // Add back puts every ticked student on the roster again; the rows leave the list at once.
    async function addBackPicked() {
        var Admin = window.PIAAdmin;
        var emails = pickedRows().map(function (tr) {
            return tr.getAttribute('data-email');
        });
        if (!emails.length) {
            return;
        }
        var back = $('#removed-addback');
        if (back) {
            back.disabled = true;
        }
        var results = await Promise.all(
            emails.map(function (email) {
                return call('admin_add_back_to_session', { p_email: email }).then(
                    function () {
                        return true;
                    },
                    function () {
                        return false;
                    }
                );
            })
        );
        var failed = results.filter(function (done) {
            return !done;
        }).length;
        say(failed ? failed + ' could not be added back.' : 'Added back.', !!failed);
        dropArchivedRows(
            emails.filter(function (email, i) {
                return results[i];
            })
        );
        refreshBehind();
    }

    // Delete is permanent: it always asks first, and lists who will be deleted.
    async function deletePicked() {
        var Admin = window.PIAAdmin;
        var rows = pickedRows();
        if (!rows.length) {
            return;
        }
        // The Archived dialog steps aside while the question is open, and comes back if the answer is Cancel.
        var archived = $('#modal-removed');
        archived.classList.add('is-suspended');
        var ok = await Admin.confirmAction({
            heading: 'Delete ' + rows.length + (rows.length === 1 ? ' student' : ' students') + ' permanently?',
            message: 'Their profile, account and responses are removed. This cannot be undone.',
            table: {
                columns: ['Student', 'Student number'],
                rows: rows.map(function (tr) {
                    // the number shown in the Archived list (masked under Privacy Mode, like everywhere else)
                    var cell = tr.querySelector('[data-number-for]');
                    return [tr.getAttribute('data-who'), cell ? cell.textContent : '—'];
                })
            },
            confirmLabel: 'Delete permanently'
        });
        archived.classList.remove('is-suspended');
        if (!ok) {
            return;
        }
        // all the deletes go together instead of one after another
        var emails = rows.map(function (tr) {
            return tr.getAttribute('data-email');
        });
        var results = await Promise.all(
            emails.map(function (email) {
                return call('admin_delete_user', { target_email: email }).then(
                    function () {
                        return true;
                    },
                    function () {
                        return false;
                    }
                );
            })
        );
        var failed = results.filter(function (done) {
            return !done;
        }).length;
        say(failed ? failed + ' could not be deleted.' : 'Deleted.', !!failed);
        dropArchivedRows(
            emails.filter(function (email, i) {
                return results[i];
            })
        );
        refreshBehind();
    }

    // Permanently delete one student (always asks first)
    async function deleteStudent(email) {
        var Admin = window.PIAAdmin;
        var ok = await Admin.confirmAction({
            heading: 'Permanently delete ' + Admin.studentLabel(email) + '?',
            message: 'Their profile, account and responses are removed. This cannot be undone.',
            confirmLabel: 'Permanently delete'
        });
        if (!ok) {
            return;
        }
        try {
            await call('admin_delete_user', { target_email: email });
            say('Deleted.');
            await Promise.all([Admin.refreshAll(), refreshOverview()]);
        } catch (error) {
            say(failure(error), true);
        }
    }

    window.PIACheckin = {
        removeStudent: askReason,
        deleteStudent: deleteStudent,
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
            renderSession();
        }
    };
})();
