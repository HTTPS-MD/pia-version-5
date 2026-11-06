/*
 * Teacher page.
 * Checks the teacher, then shows the read-only list of the section: who is online
 * and the attendance. Refreshes by itself.
 */
(function () {
    'use strict';

    var esc = escapeHTML;

    var POLL_MS = 10000;

    var state = {
        email: '',
        name: '',
        section: '',
        rows: [],
        filter: 'all',
        term: '',
        loadedAt: 0,
        loading: false,
        final: false,
        classDate: ''
    };
    var pollId = null;
    var signingOut = false;
    var started = false;

    function setText(el, text) {
        if (el) {
            el.textContent = text;
        }
    }
    function bootText(message) {
        setText($('#boot-text'), message);
    }

    function isNetworkError(err) {
        if (typeof navigator !== 'undefined' && navigator.onLine === false) {
            return true;
        }
        if (!err) {
            return false;
        }
        var code = String(err.code || '');
        var status = Number(err.status || 0);
        var msg = String(err.message || err);
        return !code && !status && /fetch|network|load failed|timed? ?out|offline/i.test(msg);
    }

    function clock(ms) {
        return new Date(ms).toLocaleTimeString([], {
            hour: '2-digit',
            minute: '2-digit',
            second: '2-digit'
        });
    }

    function leave(message, ended) {
        bootText(message);
        $('#boot').hidden = false;
        $('#app').hidden = true;
        if (ended && typeof endStaffSession === 'function') {
            setTimeout(function () {
                endStaffSession('ended');
            }, 1500);
            return;
        }
        try {
            localStorage.removeItem('pia_user_email');
        } catch (err) {}
        setTimeout(function () {
            window.location.replace('../../index.html');
        }, 3000);
    }

    async function checkAccess() {
        if (typeof sb === 'undefined' || !sb) {
            return 'no-client';
        }

        try {
            var session = await sb.auth.getSession();
            if (session.error) {
                if (isNetworkError(session.error)) {
                    return 'offline';
                }
                leave('Your session ended. Taking you to sign in…', true);
                return 'denied';
            }
            if (!session.data.session) {
                leave('Your session ended. Taking you to sign in…', true);
                return 'denied';
            }

            var email = session.data.session.user.email;
            var res = await sb
                .from('profiles')
                .select('role, section, full_name, is_ocean_done')
                .eq('email', email)
                .maybeSingle();

            if (res.error) {
                if (isNetworkError(res.error)) {
                    return 'offline';
                }
                leave('Couldn’t confirm your access. Taking you back to sign in…', true);
                return 'denied';
            }
            if (!res.data) {
                leave('Your session ended. Taking you to sign in…', true);
                return 'denied';
            }

            var role = String(res.data.role || 'student')
                .trim()
                .toLowerCase();
            if (role === 'admin') {
                window.location.replace('../../admin/html/admin-dashboard.html');
                return 'denied';
            }
            if (role === 'student') {
                window.location.replace('../../student/html/waiting-room.html');
                return 'denied';
            }
            if (role !== 'teacher') {
                leave('This page is for teachers. Taking you back to sign in…');
                return 'denied';
            }

            if (res.data.is_ocean_done !== true) {
                window.location.replace('teacher-ocean.html');
                return 'denied';
            }

            try {
                localStorage.setItem('pia_user_email', email);
            } catch (err) {}
            state.email = email;
            state.section = res.data.section || '';
            state.name = res.data.full_name || '';

            if (!state.section || !state.name) {
                var prof = await sb
                    .from('professors')
                    .select('name, assigned_section')
                    .eq('email', email)
                    .maybeSingle();
                if (prof.error && isNetworkError(prof.error)) {
                    return 'offline';
                }
                if (!state.section) {
                    state.section = (prof.data && prof.data.assigned_section) || '';
                }
                if (!state.name) {
                    state.name = (prof.data && prof.data.name) || '';
                }
            }
            return 'ok';
        } catch (err) {
            if (isNetworkError(err)) {
                return 'offline';
            }
            console.error('Teacher page: access check failed.', err);
            leave('Couldn’t confirm your access. Taking you back to sign in…', true);
            return 'denied';
        }
    }

    // Teachers with more than one section pick one from the same dropdown the admin console uses.
    async function offerSectionSwitch() {
        try {
            var res = await sb.rpc('teacher_my_sections');
            if (res.error || !res.data || res.data.length < 2) {
                return;
            }
            var title = $('#section-title');
            var host = document.createElement('span');
            host.id = 'section-host';
            var toggle = document.createElement('button');
            toggle.type = 'button';
            toggle.setAttribute('data-section-toggle', '');
            toggle.setAttribute('aria-haspopup', 'menu');
            toggle.setAttribute('aria-expanded', 'false');
            var menu = document.createElement('div');
            menu.setAttribute('data-section-menu', '');
            menu.setAttribute('role', 'menu');
            menu.className = 'custom-select-list section-menu';
            menu.hidden = true;

            var chosen = '';
            res.data.forEach(function (row) {
                var item = document.createElement('button');
                item.type = 'button';
                item.setAttribute('role', 'menuitemradio');
                item.className = 'custom-select-option section-opt' + (row.in_use ? ' is-selected' : '');
                item.textContent = row.section;
                item.setAttribute('data-section', row.section);
                menu.appendChild(item);
                if (row.in_use) {
                    chosen = row.section;
                }
            });
            toggle.textContent = chosen || state.section;
            var caret = document.createElement('span');
            caret.className = 'custom-select-chevron';
            caret.setAttribute('aria-hidden', 'true');
            toggle.appendChild(caret);

            var close = function () {
                menu.hidden = true;
                toggle.setAttribute('aria-expanded', 'false');
            };
            toggle.addEventListener('click', function () {
                menu.hidden = !menu.hidden;
                toggle.setAttribute('aria-expanded', String(!menu.hidden));
            });
            menu.addEventListener('click', async function (event) {
                var item = event.target.closest('[data-section]');
                if (!item) {
                    return;
                }
                close();
                if (item.getAttribute('data-section') === chosen) {
                    return;
                }
                toggle.disabled = true;
                var done = await sb.rpc('teacher_set_section', {
                    p_section: item.getAttribute('data-section')
                });
                if (done.error) {
                    toggle.disabled = false;
                    return;
                }
                window.location.reload();
            });
            document.addEventListener('click', function (event) {
                if (!host.contains(event.target)) {
                    close();
                }
            });
            document.addEventListener('keydown', function (event) {
                if (event.key === 'Escape') {
                    close();
                }
            });

            host.append(toggle, menu);
            title.textContent = '';
            title.appendChild(host);
        } catch (e) {}
    }

    function paintIdentity() {
        var shown = state.name || state.email.split('@')[0];
        var w = String(shown).trim().split(/\s+/).filter(Boolean);
        setText(
            $('#initials'),
            (
                (w[0] || '?')[0] + (w.length > 1 ? w[w.length - 1][0] : (w[0] || '?')[1] || '')
            ).toUpperCase()
        );
        setText($('#section-title'), state.section || 'Your section');
        document.title = (state.section ? state.section + ' · ' : '') + 'PIA System';
        $('#no-section').hidden = !!state.section;
        $('#roster-panel').hidden = !state.section;
    }

    async function load() {
        if (state.loading || !state.section) {
            return;
        }
        state.loading = true;
        try {
            var res = await sb.rpc('teacher_section_roster');
            if (res.error) {
                if (isNetworkError(res.error)) {
                    paintFoot(
                        'You are offline. Showing the roster as of ' +
                            (state.loadedAt ? clock(state.loadedAt) : 'the last load') +
                            '.'
                    );
                } else {
                    paintFoot('Couldn’t load the roster. Trying again…');
                }
                return;
            }

            state.rows = (res.data || []).map(function (r) {
                return {
                    key: String(r.student_key || ''),
                    name: String(r.full_name || 'Unnamed student'),
                    online: r.online === true,
                    attendance: r.attendance || null,
                    entered: r.entered === true,
                    enteredAt: r.entered_at || null
                };
            });
            // The same for every row: the record is final once the admin closed the Game.
            var first = (res.data || [])[0] || {};
            state.final = first.final === true;
            state.classDate = first.class_date || '';
            state.loadedAt = Date.now();
            render();
            paintFoot('Read-only. Updated ' + clock(state.loadedAt) + '.');
        } catch (err) {
            paintFoot('Couldn’t reach the server. Showing the last roster.');
        } finally {
            state.loading = false;
        }
    }

    function schedule() {
        clearTimeout(pollId);
        pollId = setTimeout(function () {
            if (document.hidden || signingOut) {
                schedule();
                return;
            }
            load().then(schedule);
        }, POLL_MS);
    }

    function paintFoot(text) {
        setText($('#foot'), text);
    }

    function matches(row) {
        if (state.filter === 'online' && !row.online) {
            return false;
        }
        var term = state.term.trim().toLowerCase();
        return !term || row.name.toLowerCase().indexOf(term) !== -1;
    }

    // Live: Entered (full colour while the student is online, faded after they leave). Final: Present, Absent or
    // Did not participate (marked Present but never entered).
    function attendanceCell(td, row) {
        var value = row.attendance;
        if (value === 'present' && !state.final && row.entered) {
            td.className = 't-att-in' + (row.online ? '' : ' is-away');
            td.textContent = 'Entered';
        } else if (value === 'present') {
            td.className = 't-att-present';
            td.textContent = '✓ Present';
        } else if (value === 'did_not_participate') {
            td.className = 't-att-dnp';
            td.textContent = 'Did not participate';
        } else if (value === 'absent') {
            td.className = 't-att-absent';
            td.textContent = '✗ Absent';
        } else if (value === 'not_marked') {
            td.className = 'muted';
            td.textContent = 'Not marked';
        } else {
            td.className = 'muted';
            td.textContent = '—';
        }
    }

    function render() {
        var counts = { all: state.rows.length, online: 0 };
        state.rows.forEach(function (r) {
            if (r.online) {
                counts.online++;
            }
        });
        $$('[data-count]').forEach(function (n) {
            setText(n, counts[n.getAttribute('data-count')]);
        });

        setText(
            $('#dir-count'),
            state.rows.length + (state.rows.length === 1 ? ' student' : ' students')
        );
        var classOpen = state.rows.some(function (r) {
            return r.attendance !== null;
        });
        $('#class-live-dot').classList.toggle('is-on', classOpen);
        setText(
            $('#class-live-status'),
            state.final ? 'Attendance is final' : classOpen ? 'Class is open' : 'Study is not yet started'
        );
        // .btn sets its own display, which beats [hidden]: the is-hidden class does the hiding.
        $('#download-att').classList.toggle('is-hidden', !state.final);

        var visible = state.rows.filter(matches);
        var body = $('#roster');
        body.innerHTML = '';
        visible.forEach(function (r) {
            var tr = document.createElement('tr');

            var who = document.createElement('td');
            var user = document.createElement('div');
            user.className = 'cell-user';
            var wrap = document.createElement('span');
            wrap.className = 'avatar-wrap';
            var avatar = document.createElement('span');
            avatar.className = 'avatar';
            avatar.setAttribute('aria-hidden', 'true');
            var words = r.name.trim().split(/\s+/).filter(Boolean);
            avatar.textContent = (
                (words[0] || '?')[0] + (words.length > 1 ? words[words.length - 1][0] : '')
            ).toUpperCase();
            var dot = document.createElement('span');
            dot.className = 'avatar-dot' + (r.online ? ' is-online' : '');
            dot.title = r.online ? 'Online' : 'Offline';
            wrap.append(avatar, dot);
            var text = document.createElement('span');
            text.className = 'cell-user-text';
            var name = document.createElement('span');
            name.className = 't-name';
            name.textContent = r.name;
            text.appendChild(name);
            user.append(wrap, text);
            who.appendChild(user);

            var att = document.createElement('td');
            attendanceCell(att, r);

            tr.appendChild(who);
            tr.appendChild(att);
            body.appendChild(tr);
        });

        var empty = $('#roster-empty');
        empty.classList.toggle('is-hidden', visible.length > 0);
        setText(
            $('#roster-empty-text'),
            state.rows.length ? 'No matching students' : 'No students in this section yet'
        );
    }

    // One line per student, opened in Excel. Only the name, the section, the date, the status and the time entered:
    // no student number, group, stage or result. A name that starts like a formula is made safe.
    function csvCell(value) {
        var text = String(value == null ? '' : value);
        if (/^[=+\-@\t\r]/.test(text)) {
            text = "'" + text;
        }
        return '"' + text.replace(/"/g, '""') + '"';
    }
    var STATUS_WORDS = {
        present: 'Present',
        absent: 'Absent',
        did_not_participate: 'Did not participate',
        not_marked: 'Not marked'
    };
    function downloadAttendance() {
        var clockFmt = new Intl.DateTimeFormat('en-GB', {
            timeZone: 'Asia/Manila',
            hour: '2-digit',
            minute: '2-digit',
            hour12: false
        });
        var lines = [['Name', 'Section', 'Date', 'Status', 'Time entered'].map(csvCell).join(',')];
        state.rows.forEach(function (r) {
            lines.push(
                [
                    r.name,
                    state.section,
                    state.classDate,
                    STATUS_WORDS[r.attendance] || '',
                    r.enteredAt ? clockFmt.format(new Date(r.enteredAt)) : ''
                ]
                    .map(csvCell)
                    .join(',')
            );
        });
        var blob = new Blob(['\ufeff' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
        var link = document.createElement('a');
        link.href = URL.createObjectURL(blob);
        link.download = 'attendance-' + (state.section || 'section') + '-' + state.classDate + '.csv';
        document.body.appendChild(link);
        link.click();
        link.remove();
        setTimeout(function () {
            URL.revokeObjectURL(link.href);
        }, 1000);
    }

    function bindControls() {
        $('#download-att').addEventListener('click', downloadAttendance);
        $('#filters').addEventListener('click', function (event) {
            var tab = event.target.closest('[data-filter]');
            if (!tab) {
                return;
            }
            state.filter = tab.getAttribute('data-filter');
            $$('[data-filter]').forEach(function (t) {
                var on = t === tab;
                t.classList.toggle('is-active', on);
                t.setAttribute('aria-pressed', on ? 'true' : 'false');
            });
            render();
        });

        $('#find').addEventListener('input', function (event) {
            state.term = event.target.value;
            render();
        });

        var toggle = $('#theme-toggle');
        var sync = function () {
            toggle.setAttribute(
                'aria-label',
                document.documentElement.getAttribute('data-theme') === 'light'
                    ? 'Switch to dark theme'
                    : 'Switch to light theme'
            );
        };
        toggle.addEventListener('click', function () {
            var next =
                document.documentElement.getAttribute('data-theme') === 'light' ? 'dark' : 'light';
            document.documentElement.setAttribute('data-theme', next);
            try {
                localStorage.setItem('pia_theme', next);
            } catch (e) {}
            sync();
        });
        sync();

        $('#signout').addEventListener('click', function () {
            if (signingOut) {
                return;
            }
            signingOut = true;
            clearTimeout(pollId);
            this.disabled = true;
            this.textContent = 'Signing out…';

            setTimeout(function () {
                try {
                    localStorage.clear();
                    sessionStorage.clear();
                } catch (e) {}
                window.location.replace('../../index.html');
            }, 8000);
            if (typeof executeForceLogout === 'function') {
                executeForceLogout();
            } else {
                window.location.replace('../../index.html');
            }
        });

        document.addEventListener('visibilitychange', function () {
            if (!document.hidden) {
                load().then(schedule);
            }
        });
    }

    function route() {
        var settings = window.location.hash === '#settings';
        var help = window.location.hash === '#help';
        $('#view-students').hidden = settings || help;
        $('#view-settings').hidden = !settings;
        $('#view-help').hidden = !help;
        $('#tab-sections').classList.toggle('is-active', !settings && !help);
        if (help) {
            document.title = 'Help · PIA System';
        } else if (settings) {
            document.title = 'Settings · PIA System';
            if (window.PIATeacherSettings) {
                window.PIATeacherSettings.show({ email: state.email, name: state.name });
            }
        } else {
            document.title = (state.section ? state.section + ' · ' : '') + 'PIA System';
        }
        closeMenu();
        window.scrollTo(0, 0);
    }

    function closeMenu() {
        var menu = $('#account-menu');
        if (!menu || menu.hidden) {
            return;
        }
        menu.hidden = true;
        $('#account-btn').setAttribute('aria-expanded', 'false');
    }

    function bindMenu() {
        var btn = $('#account-btn');
        var menu = $('#account-menu');
        btn.addEventListener('click', function () {
            menu.hidden = !menu.hidden;
            btn.setAttribute('aria-expanded', menu.hidden ? 'false' : 'true');
            if (!menu.hidden) {
                var first = menu.querySelector('[role="menuitem"]');
                if (first) {
                    first.focus();
                }
            }
        });
        document.addEventListener('click', function (event) {
            if (!$('#account').contains(event.target)) {
                closeMenu();
            }
        });
        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape') {
                closeMenu();
                btn.focus();
            }
        });
        window.addEventListener('hashchange', route);
    }

    async function start() {
        $('#boot-retry').hidden = true;
        bootText('Checking your access…');

        var access = await checkAccess();
        if (access === 'offline' || access === 'no-client') {
            bootText(
                access === 'offline'
                    ? 'Can’t reach the server. Check the connection, then try again.'
                    : 'Something did not load. Reload the page.'
            );
            $('#boot-retry').hidden = false;
            return;
        }
        if (access !== 'ok') {
            return;
        }

        if (!started) {
            started = true;

            if (typeof startStaffSessionWatch === 'function') {
                startStaffSessionWatch();
            }

            if (typeof startIdleWatchdog === 'function') {
                startIdleWatchdog({ limitMs: 15 * 60 * 1000 });
            }
            bindControls();
            bindMenu();
        }

        paintIdentity();
        $('#boot').hidden = true;
        $('#app').hidden = false;
        document.body.removeAttribute('data-boot');

        offerSectionSwitch();
        route();
        if (state.section) {
            await load();
            schedule();
        }
    }

    $('#boot-retry').addEventListener('click', start);

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
    } else {
        start();
    }
})();
