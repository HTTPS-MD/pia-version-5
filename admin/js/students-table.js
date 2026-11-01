/*
 * Students table.
 * The list of students with online status, stage, minutes, filters and the section picker.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function hasCurrentResult(s) {
        return (
            s.is_ocean_done === true &&
            !!(
                Admin.state.resultEmails &&
                Admin.state.resultEmails[String(s.email || '').toLowerCase()]
            )
        );
    }

    function stageOf(profile) {
        // Control students never play the game: once OCEAN is done they sit on the thank-you page.
        if (profile.group_type === 'control' && profile.is_ocean_done === true) {
            return 'Thank You';
        }
        // The in-game flag can linger after a student leaves the game; only trust it on the game stage.
        if (
            profile.is_in_game &&
            (!profile.current_stage || profile.current_stage === 'Tutoring Dashboard')
        ) {
            return 'Active Game';
        }
        return profile.current_stage || null;
    }
    Admin.stageOf = stageOf;

    function isOnline(profile) {
        if (!profile || !Object.prototype.hasOwnProperty.call(profile, 'active_devices')) {
            return null;
        }
        return (profile.active_devices || []).length > 0;
    }
    Admin.isOnline = isOnline;

    function avatarMarkup(profile) {
        var online = isOnline(profile);
        var dot =
            online === null
                ? ''
                : '<span class="avatar-dot' +
                  (online ? ' is-online' : '') +
                  '" data-presence="' +
                  Admin.esc(profile.email) +
                  '"' +
                  ' title="' +
                  (online ? 'Signed in' : 'Signed out') +
                  '"></span>';

        return (
            '<span class="avatar-wrap">' +
            '<span class="avatar">' +
            Admin.esc(Admin.initialsOf(profile.full_name, profile.email)) +
            '</span>' +
            dot +
            '</span>'
        );
    }

    function userCell(profile) {
        return (
            '' +
            '<div class="cell-user">' +
            avatarMarkup(profile) +
            '<span class="cell-user-text">' +
            '<span class="cell-name">' +
            Admin.esc(profile.full_name || '(no name)') +
            '</span>' +
            (/@students\.pia\.invalid$/i.test(String(profile.email || ''))
                ? ''
                : '<span class="cell-mail">' + Admin.esc(profile.email) + '</span>') +
            '</span>' +
            '</div>'
        );
    }
    Admin.userCell = userCell;

    function applyPresence(email, online) {
        $$('[data-presence="' + (email || '').replace(/"/g, '\\"') + '"]').forEach(function (dot) {
            dot.classList.toggle('is-online', !!online);
            dot.title = online ? 'Signed in' : 'Signed out';
        });
    }
    Admin.applyPresence = applyPresence;

    function stageLabel(stageKey) {
        if (!stageKey) {
            return '—';
        }
        return Admin.STAGE_META[stageKey] ? Admin.STAGE_META[stageKey].label : stageKey;
    }
    Admin.stageLabel = stageLabel;

    function stageBadge(stageKey) {
        if (!stageKey) {
            return '<span class="muted">—</span>';
        }
        return '<span class="badge">' + Admin.esc(stageLabel(stageKey)) + '</span>';
    }

    var liveRefreshId = null;

    function refreshStageTimes() {
        if (document.hidden || !Admin.state.cohortLoaded) {
            return;
        }
        Admin.loadStageTimes()
            .then(function () {
                renderSections();
                paintStageTimes();
            })
            .catch(function () {});
    }

    function startLiveSessionsTimer() {
        if (liveRefreshId !== null) {
            return;
        }
        liveRefreshId = setInterval(refreshStageTimes, 20000);
        document.addEventListener('visibilitychange', function () {
            if (!document.hidden) {
                refreshStageTimes();
            }
        });
        window.addEventListener('pagehide', function () {
            clearInterval(liveRefreshId);
            liveRefreshId = null;
        });
    }
    Admin.startLiveSessionsTimer = startLiveSessionsTimer;

    function oceanFraction(done, total) {
        return total ? done + ' of ' + total + ' (' + Admin.pct(done, total) + '%)' : '—';
    }

    function renderSections() {
        renderScope();
        var tbody = $('#sections-tbody');
        if (!tbody) {
            return;
        }

        if (!Admin.state.sectionsLoaded || !Admin.state.cohortLoaded) {
            tbody.innerHTML = Admin.skeletonRows(3, 4);
            return;
        }

        if (!Admin.state.sections.length) {
            tbody.innerHTML =
                '<tr><td colspan="3"><div class="state-block">' +
                '<p class="state-title">No sections yet</p></div></td></tr>';
            return;
        }

        tbody.innerHTML = Admin.state.sections
            .map(function (section) {
                var members = Admin.state.cohort.filter(function (s) {
                    return s.section === section.name;
                });
                var prof = Admin.state.faculty.filter(function (f) {
                    return f.assigned_section === section.name;
                })[0];
                var name = Admin.esc(section.name);
                var cell;
                var actions;
                if (sectionEdit.rename === section.name) {
                    cell =
                        '<input class="input input-sm" data-section-input maxlength="40" value="' +
                        name +
                        '" aria-label="New name for ' +
                        name +
                        '">' +
                        (sectionEdit.error
                            ? '<p class="field-error" role="alert">' +
                              Admin.esc(sectionEdit.error) +
                              '</p>'
                            : '');
                    actions =
                        '<button type="button" class="btn btn-primary btn-sm" data-section-save="' +
                        name +
                        '">Save</button> ' +
                        '<button type="button" class="btn btn-secondary btn-sm" data-section-cancel>Cancel</button>';
                } else if (sectionEdit.remove === section.name) {
                    cell =
                        name +
                        (sectionEdit.error
                            ? '<p class="field-error" role="alert">' +
                              Admin.esc(sectionEdit.error) +
                              '</p>'
                            : '<p class="scope-line">Delete this section? This cannot be undone.</p>');
                    actions =
                        '<button type="button" class="btn btn-danger btn-sm" data-section-confirm="' +
                        name +
                        '">Delete</button> ' +
                        '<button type="button" class="btn btn-secondary btn-sm" data-section-cancel>Keep</button>';
                } else {
                    var why = members.length ? 'Has students' : prof ? 'Has a professor' : '';
                    cell = name;
                    actions =
                        '<button type="button" class="btn btn-secondary btn-sm" data-section-rename="' +
                        name +
                        '">Rename</button> ' +
                        '<button type="button" class="btn btn-secondary btn-sm" data-section-remove="' +
                        name +
                        '"' +
                        (why
                            ? ' disabled title="' + why + ': only an empty section can be deleted."'
                            : '') +
                        '>Delete</button>';
                }
                return (
                    '<tr><td>' +
                    cell +
                    '</td>' +
                    '<td class="col-right mono">' +
                    members.length +
                    '</td>' +
                    '<td class="col-right">' +
                    actions +
                    '</td></tr>'
                );
            })
            .join('');
        var input = tbody.querySelector('[data-section-input]');
        if (input && !sectionEdit.focused) {
            sectionEdit.focused = true;
            input.focus();
            input.select();
        }
    }
    Admin.renderSections = renderSections;

    var sectionEdit = { rename: null, remove: null, error: '', focused: false };

    function renderScope() {
        var line = $('#scope-line');
        if (!line) {
            return;
        }
        var section = Admin.allSectionsOn() ? '' : Admin.state.filters.section;
        var scores = $('#section-scores-open');
        if (scores) {
            scores.classList.toggle('is-hidden', !section);
        }
        var search = $('#student-search');
        if (search) {
            search.placeholder = 'Search all students';
        }

        if (!Admin.state.cohortLoaded) {
            line.textContent = 'Loading…';
            return;
        }

        var members = section
            ? Admin.state.cohort.filter(function (s) {
                  return s.section === section;
              })
            : Admin.state.cohort;
        var done = members.filter(hasCurrentResult).length;
        var parts = section ? [] : ['All sections'];
        parts.push(members.length + (members.length === 1 ? ' student' : ' students'));
        if (members.length) {
            parts.push('OCEAN completed ' + oceanFraction(done, members.length));
        }
        line.textContent = parts.join(' · ');
        Admin.state.summary = { section: section, total: members.length, done: done };
        var dir = $('#directory-count');
        if (dir) {
            dir.textContent = members.length + (members.length === 1 ? ' student' : ' students');
        }
        document.dispatchEvent(new Event('pia:scope'));
    }

    function showSection(name) {
        Admin.state.filters = { section: name || '', group: 'all', stage: null, search: '' };
        Admin.state.page = 1;
        var filter = $('#section-filter');
        if (filter) {
            filter.value = Admin.state.filters.section;
        }
        $('#group-filter').value = 'all';
        refreshCustomSelect('section-filter');
        refreshCustomSelect('group-filter');
        $('#student-search').value = '';
        Admin.state.allSections = false;
        window.PIAAllSections = false;
        document.documentElement.classList.remove('pia-all-sections');
        setStageTab('');
        renderScope();
        Admin.switchView('students');
        Admin.loadRoster();
        Admin.loadStageCounters();
    }
    Admin.showSection = showSection;

    function initSectionsTable() {
        var tbody = $('#sections-tbody');
        function reset() {
            sectionEdit = { rename: null, remove: null, error: '', focused: false };
            renderSections();
        }
        async function run(button, call, done) {
            button.disabled = true;
            var res = await call;
            if (res.error) {
                sectionEdit.error = (res.error.message || 'Something went wrong.').replace(
                    /^PIA:\s*/,
                    ''
                );
                renderSections();
                return;
            }
            reset();
            Admin.toastOk(done[0], done[1]);
            Admin.refreshAll();
        }
        function save(button) {
            var input = tbody.querySelector('[data-section-input]');
            var old = button.getAttribute('data-section-save');
            var next = input ? input.value.trim() : '';
            if (!next || next === old) {
                reset();
                return;
            }
            run(button, sb.rpc('admin_rename_section', { p_old: old, p_new: next }), [
                'Section renamed',
                old + ' is now ' + next + '.'
            ]);
        }
        tbody.addEventListener('click', function (event) {
            var t = function (sel) {
                return event.target.closest(sel);
            };
            var b;
            if ((b = t('[data-section-rename]'))) {
                sectionEdit = {
                    rename: b.getAttribute('data-section-rename'),
                    remove: null,
                    error: '',
                    focused: false
                };
                renderSections();
            } else if ((b = t('[data-section-remove]'))) {
                sectionEdit = {
                    rename: null,
                    remove: b.getAttribute('data-section-remove'),
                    error: '',
                    focused: false
                };
                renderSections();
            } else if (t('[data-section-cancel]')) {
                reset();
            } else if ((b = t('[data-section-save]'))) {
                save(b);
            } else if ((b = t('[data-section-confirm]'))) {
                var name = b.getAttribute('data-section-confirm');
                run(b, sb.rpc('admin_delete_section', { p_name: name }), [
                    'Section deleted',
                    name + ' was removed.'
                ]);
            }
        });
        tbody.addEventListener('keydown', function (event) {
            if (!event.target.matches('[data-section-input]')) {
                return;
            }
            if (event.key === 'Enter') {
                event.preventDefault();
                var b = tbody.querySelector('[data-section-save]');
                if (b) {
                    save(b);
                }
            } else if (event.key === 'Escape') {
                event.preventDefault();
                reset();
            }
        });
        var dialog = $('#modal-manage-sections');
        if (dialog) {
            new MutationObserver(function () {
                if (!dialog.classList.contains('is-open')) {
                    reset();
                }
            }).observe(dialog, { attributes: true, attributeFilter: ['class'] });
        }
    }
    Admin.initSectionsTable = initSectionsTable;

    function rosterRow(s, cells) {
        return (
            '<tr class="is-clickable" tabindex="0" data-student="' +
            Admin.esc(s.email) +
            '"' +
            ' aria-label="Open profile: ' +
            Admin.esc(s.full_name || s.email) +
            '">' +
            '<td>' +
            userCell(s) +
            '</td>' +
            cells +
            '</tr>'
        );
    }

    function conditionCell(s) {
        var condition = Admin.CONDITIONS[s.group_type] || { short: s.group_type || '—', badge: '' };
        return (
            '<td><span class="badge ' +
            condition.badge +
            '">' +
            Admin.esc(condition.short) +
            '</span></td>'
        );
    }

    function filtersActive() {
        return !!(
            Admin.state.filters.section ||
            Admin.state.filters.stage ||
            Admin.state.filters.group !== 'all' ||
            Admin.state.filters.search.trim()
        );
    }

    function stageMinutes(s, field, applies) {
        var row = Admin.state.stageTimes
            ? Admin.state.stageTimes[String(s.email || '').toLowerCase()]
            : null;
        var seconds = row ? Number(row[field]) : NaN;
        if (!applies || !isFinite(seconds) || seconds <= 0) {
            return '—';
        }
        return seconds < 60 ? '<1 min' : Math.round(seconds / 60) + ' min';
    }

    function stageTimeCells(s) {
        var group = s.group_type;
        var cell = function (key, field, applies) {
            return (
                '<td class="mono" data-stage-time="' +
                key +
                '">' +
                Admin.esc(stageMinutes(s, field, applies)) +
                '</td>'
            );
        };
        return (
            cell('ocean', 'ocean_time', true) +
            cell('character', 'character_select_time', group === 'non-assigned') +
            cell('tutoring', 'tutoring_time', group !== 'control')
        );
    }

    function paintStageTimes() {
        var byEmail = {};
        Admin.state.rosterPage.forEach(function (s) {
            byEmail[String(s.email || '').toLowerCase()] = s;
        });
        $$('#student-tbody tr[data-student]').forEach(function (tr) {
            var s = byEmail[String(tr.getAttribute('data-student') || '').toLowerCase()];
            if (!s) {
                return;
            }
            var group = s.group_type;
            var set = function (key, field, applies) {
                var td = tr.querySelector('[data-stage-time="' + key + '"]');
                if (td) {
                    td.textContent = stageMinutes(s, field, applies);
                }
            };
            set('ocean', 'ocean_time', true);
            set('character', 'character_select_time', group === 'non-assigned');
            set('tutoring', 'tutoring_time', group !== 'control');
        });
    }

    function renderRoster() {
        var tbody = $('#student-tbody');
        var empty = $('#student-empty');

        var none = Admin.state.rosterPage.length === 0;
        empty.classList.toggle('is-hidden', !none);
        $('#reset-filters').classList.toggle('is-hidden', !filtersActive());
        $('#student-empty .state-title').textContent = filtersActive()
            ? 'No matching students'
            : 'No students yet';

        tbody.innerHTML = Admin.state.rosterPage
            .map(function (s) {
                return rosterRow(
                    s,
                    '<td>' +
                        Admin.esc(s.section || '—') +
                        '</td>' +
                        conditionCell(s) +
                        '<td>' +
                        stageBadge(stageOf(s)) +
                        '</td>' +
                        stageTimeCells(s)
                );
            })
            .join('');

        var pages = Math.max(1, Math.ceil(Admin.state.totalStudents / Admin.PAGE_SIZE));
        var from = Admin.state.totalStudents ? (Admin.state.page - 1) * Admin.PAGE_SIZE + 1 : 0;
        var to = Math.min(Admin.state.page * Admin.PAGE_SIZE, Admin.state.totalStudents);

        $('#pager-info').textContent = Admin.state.totalStudents
            ? 'Showing ' +
              from +
              '–' +
              to +
              ' of ' +
              Admin.state.totalStudents +
              (pages > 1 ? ' · page ' + Admin.state.page + ' of ' + pages : '')
            : 'No students to show';
        $('#page-prev').disabled = Admin.state.page <= 1;
        $('#page-next').disabled = Admin.state.page >= pages;

        if (window.PIACheckin) {
            window.PIACheckin.decorateRoster();
        }
    }
    Admin.renderRoster = renderRoster;

    function setStageTab(key) {
        Admin.state.filters.stage = key || null;
        $$('[data-stage-filter]').forEach(function (tab) {
            var on = (tab.getAttribute('data-stage-filter') || '') === (key || '');
            tab.classList.toggle('is-active', on);
            tab.setAttribute('aria-pressed', on ? 'true' : 'false');
        });
    }

    var customSelects = {};
    Admin.customSelects = customSelects;

    function refreshCustomSelect(id) {
        if (customSelects[id]) {
            customSelects[id].refresh();
        }
    }
    Admin.refreshCustomSelect = refreshCustomSelect;

    var customSelectCount = 0;

    function initCustomSelect(target) {
        var select = typeof target === 'string' ? $('#' + target) : target;
        if (!select || select._customSelect) {
            return;
        }
        select._customSelect = true;
        if (!select.id) {
            customSelectCount += 1;
            select.id = 'cs-' + customSelectCount;
        }
        var id = select.id;
        var box = document.createElement('div');
        var trigger = document.createElement('button');
        var list = document.createElement('div');
        var active = 0;
        var open = false;
        box.className = 'custom-select';
        trigger.type = 'button';
        trigger.className = 'custom-select-trigger';
        trigger.setAttribute('role', 'combobox');
        trigger.setAttribute('aria-haspopup', 'listbox');
        trigger.setAttribute('aria-expanded', 'false');
        trigger.setAttribute('aria-controls', id + '-list');
        var labelEl = document.querySelector('label[for="' + id + '"]');
        var name = select.getAttribute('aria-label') || (labelEl ? labelEl.textContent.trim() : '');
        if (name) {
            trigger.setAttribute('aria-label', name);
        }
        list.className = 'custom-select-list';
        list.id = id + '-list';
        list.setAttribute('role', 'listbox');
        if (name) {
            list.setAttribute('aria-label', name);
        }
        list.hidden = true;
        box.appendChild(trigger);
        select.insertAdjacentElement('afterend', box);

        select.hidden = true;
        select.tabIndex = -1;
        select.setAttribute('aria-hidden', 'true');

        function options() {
            return Array.prototype.slice.call(select.options);
        }
        function paint() {
            Array.prototype.forEach.call(list.children, function (item, i) {
                var chosen = i === select.selectedIndex;
                item.classList.toggle('is-selected', chosen);
                item.classList.toggle('is-active', i === active);
                item.setAttribute('aria-selected', chosen ? 'true' : 'false');
            });
            if (open && list.children[active]) {
                trigger.setAttribute('aria-activedescendant', list.children[active].id);
                list.children[active].scrollIntoView({ block: 'nearest' });
            } else {
                trigger.removeAttribute('aria-activedescendant');
            }
        }
        function refresh() {
            var opts = options();
            var chosen = opts[select.selectedIndex] || opts[0];
            trigger.innerHTML =
                '<span class="custom-select-value" id="' +
                id +
                '-value"></span><span class="custom-select-chevron" aria-hidden="true"></span>';
            trigger.querySelector('.custom-select-value').textContent = chosen
                ? chosen.textContent.trim()
                : '';
            list.replaceChildren();
            opts.forEach(function (option, i) {
                var item = document.createElement('div');
                item.className = 'custom-select-option';
                item.id = id + '-option-' + i;
                item.setAttribute('role', 'option');
                item.dataset.index = i;
                var label = option.textContent.trim();
                if (label.indexOf('· ') === 0) {
                    item.classList.add('is-suboption');
                    label = label.slice(2);
                }
                item.textContent = label;
                list.appendChild(item);
            });
            active = Math.max(0, select.selectedIndex);
            paint();
        }
        function close(restoreFocus) {
            if (!open) {
                return;
            }
            open = false;
            list.hidden = true;
            list.remove();
            window.removeEventListener('resize', onViewportChange);
            document.removeEventListener('scroll', onViewportChange, true);
            trigger.setAttribute('aria-expanded', 'false');
            paint();
            if (restoreFocus) {
                trigger.focus({ preventScroll: true });
            }
        }
        function place() {
            var r = trigger.getBoundingClientRect();
            var room = 12;
            var below = window.innerHeight - r.bottom - room;
            var above = r.top - room;
            var want = Math.min(list.scrollHeight + 2, 288);
            var flip = below < want && above > below;
            var max = Math.max(96, Math.min(288, flip ? above : below));
            list.style.minWidth = r.width + 'px';
            list.style.left = Math.max(8, Math.min(r.left, window.innerWidth - r.width - 8)) + 'px';
            list.style.maxHeight = max + 'px';
            if (flip) {
                list.style.top = 'auto';
                list.style.bottom = window.innerHeight - r.top + 4 + 'px';
            } else {
                list.style.bottom = 'auto';
                list.style.top = r.bottom + 4 + 'px';
            }
        }
        function onViewportChange(event) {
            if (event && event.type === 'scroll' && list.contains(event.target)) {
                return;
            }
            close(false);
        }
        function show() {
            Object.keys(customSelects).forEach(function (key) {
                if (key !== id) {
                    customSelects[key].close();
                }
            });
            refresh();
            open = true;
            document.body.appendChild(list);
            list.hidden = false;
            place();
            window.addEventListener('resize', onViewportChange);
            document.addEventListener('scroll', onViewportChange, true);
            trigger.setAttribute('aria-expanded', 'true');
            paint();
        }
        function choose(index) {
            var option = options()[index];
            if (!option || option.disabled) {
                return;
            }
            select.value = option.value;
            select.dispatchEvent(new Event('change', { bubbles: true }));
            refresh();
            close(true);
        }
        trigger.addEventListener('click', function () {
            open ? close(false) : show();
        });
        trigger.addEventListener('keydown', function (event) {
            var count = options().length;
            if (event.key === 'Escape') {
                if (open) {
                    event.preventDefault();
                    close(true);
                }
                return;
            }
            if (event.key === 'Tab') {
                close(false);
                return;
            }
            if (
                event.key === 'ArrowDown' ||
                event.key === 'ArrowUp' ||
                event.key === 'Home' ||
                event.key === 'End'
            ) {
                event.preventDefault();
                if (!open) {
                    show();
                }
                if (event.key === 'Home') {
                    active = 0;
                } else if (event.key === 'End') {
                    active = count - 1;
                } else {
                    active = (active + (event.key === 'ArrowDown' ? 1 : -1) + count) % count;
                }
                paint();
            } else if ((event.key === 'Enter' || event.key === ' ') && open) {
                event.preventDefault();
                choose(active);
            }
        });
        list.addEventListener('click', function (event) {
            var item = event.target.closest('[data-index]');
            if (item) {
                choose(Number(item.dataset.index));
            }
        });
        function onPointerDown(event) {
            if (open && !box.contains(event.target) && !list.contains(event.target)) {
                close(false);
            }
        }
        document.addEventListener('pointerdown', onPointerDown);
        select.addEventListener('change', refresh);
        // Keep the trigger in step when code fills the options or sets the value.
        new MutationObserver(refresh).observe(select, { childList: true });
        ['value', 'selectedIndex'].forEach(function (prop) {
            var native = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, prop);
            Object.defineProperty(select, prop, {
                get: function () {
                    return native.get.call(this);
                },
                set: function (v) {
                    native.set.call(this, v);
                    refresh();
                }
            });
        });
        customSelects[id] = {
            refresh: refresh,
            close: close,

            destroy: function () {
                close(false);
                list.remove();
                document.removeEventListener('pointerdown', onPointerDown);
                delete customSelects[id];
            }
        };
        refresh();
    }
    Admin.initCustomSelect = initCustomSelect;

    // Every dropdown in the console is the custom one: enhance what is on the page and what is added later.
    function initCustomSelects() {
        $$('select').forEach(initCustomSelect);
        new MutationObserver(function (records) {
            records.forEach(function (record) {
                record.addedNodes.forEach(function (node) {
                    if (node.nodeType !== 1) {
                        return;
                    }
                    if (node.matches('select')) {
                        initCustomSelect(node);
                    }
                    $$('select', node).forEach(initCustomSelect);
                });
                record.removedNodes.forEach(function (node) {
                    if (node.nodeType !== 1) {
                        return;
                    }
                    var gone = node.matches('select') ? [node] : Array.prototype.slice.call(node.querySelectorAll('select'));
                    gone.forEach(function (sel) {
                        if (sel._customSelect && !document.body.contains(sel) && customSelects[sel.id]) {
                            customSelects[sel.id].destroy();
                        }
                    });
                });
            });
        }).observe(document.body, { childList: true, subtree: true });
    }
    Admin.initCustomSelects = initCustomSelects;

    function initRoster() {
        $('#student-search').addEventListener(
            'input',
            Admin.debounce(function (event) {
                Admin.state.filters.search = event.target.value;
                Admin.state.page = 1;
                // Typing searches every student, whatever section is open; clearing returns to the section.
                var on = event.target.value.trim() !== '';
                var changed = on !== !!Admin.state.allSections;
                Admin.state.allSections = on;
                window.PIAAllSections = on;
                document.documentElement.classList.toggle('pia-all-sections', on);
                renderScope();
                Admin.loadRoster();
                if (changed) {
                    Admin.loadStageCounters();
                    if (window.PIACheckin && window.PIACheckin.refresh) {
                        window.PIACheckin.refresh();
                    }
                }
            }, 300)
        );

        $('#group-filter').addEventListener('change', function (event) {
            Admin.state.filters.group = event.target.value;
            Admin.state.page = 1;
            Admin.loadRoster();
            Admin.loadStageCounters();
        });

        $('#section-filter').addEventListener('change', function (event) {
            Admin.state.filters.section = event.target.value;
            Admin.state.page = 1;
            renderScope();
            Admin.loadRoster();
            Admin.loadStageCounters();
        });

        $('#section-scores-open').addEventListener('click', function () {
            if (Admin.state.filters.section) {
                Admin.openScoresModal(Admin.state.filters.section);
            }
        });

        $$('[data-stage-filter]').forEach(function (tab) {
            tab.addEventListener('click', function () {
                setStageTab(tab.getAttribute('data-stage-filter'));
                Admin.state.page = 1;
                Admin.loadRoster();
            });
        });

        $('#reset-filters').addEventListener('click', function () {
            Admin.state.filters = { section: '', group: 'all', stage: null, search: '' };
            $('#student-search').value = '';
            Admin.state.allSections = false;
            window.PIAAllSections = false;
            document.documentElement.classList.remove('pia-all-sections');
            $('#group-filter').value = 'all';
            $('#section-filter').value = '';
            refreshCustomSelect('group-filter');
            refreshCustomSelect('section-filter');
            setStageTab('');
            Admin.state.page = 1;
            renderScope();
            Admin.loadRoster();
            Admin.loadStageCounters();
        });

        $('#page-prev').addEventListener('click', function () {
            if (Admin.state.page > 1) {
                Admin.state.page--;
                Admin.loadRoster();
            }
        });

        $('#page-next').addEventListener('click', function () {
            var pages = Math.max(1, Math.ceil(Admin.state.totalStudents / Admin.PAGE_SIZE));
            if (Admin.state.page < pages) {
                Admin.state.page++;
                Admin.loadRoster();
            }
        });

        $('#student-tbody').addEventListener('click', function (event) {
            var row = event.target.closest('[data-student]');
            if (row) {
                Admin.openStudentDrawer(row.getAttribute('data-student'), row);
            }
        });

        $('#student-tbody').addEventListener('keydown', function (event) {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            var row = event.target.closest('[data-student]');
            if (!row || event.target !== row) {
                return;
            }
            event.preventDefault();
            Admin.openStudentDrawer(row.getAttribute('data-student'), row);
        });
    }
    Admin.initRoster = initRoster;
})();
