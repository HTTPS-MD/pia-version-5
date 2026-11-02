/* PIA ADMIN CONSOLE -- ADD STUDENTS */
(function () {
    'use strict';

    var esc = escapeHTML;

    var INTERNAL_DOMAIN = 'students.pia.invalid';
    var GROUPS = [
        ['assigned', 'EXP · Assigned persona'],
        ['non-assigned', 'EXP · Free choice'],
        ['neutral', 'EXP · Neutral persona'],
        ['control', 'CTRL · Traditional']
    ];
    var FIELDS = ['last', 'first', 'mid', 'num', 'grp'];
    var START_ROWS = 1;

    var MSG = {
        last: 'Enter the last name',
        first: 'Enter the first name',
        numEmpty: 'Enter the student number',
        numLength: 'Student number must be 11 digits',
        numTaken: function (who) {
            return who + ' already has this number';
        },
        numTwice: function (n) {
            return 'This number is also in row ' + n;
        },
        section: 'Choose a section',
        group: 'Choose a condition for this student',
        nobody: 'Add at least one student',
        problem: 'There is a problem',
        fixRows: function (n) {
            return n === 1
                ? 'Fix the row with a message below, then add the students.'
                : 'Fix the ' + n + ' rows with a message below, then add the students.';
        },
        cantCheck: 'Couldn’t check the student numbers. Try again',
        added: function (n) {
            return n === 1 ? '1 student added' : n + ' students added';
        },
        notAdded: function (name) {
            return 'Couldn’t add ' + name;
        },
        exists: 'A student with this number is already on the roster',
        noAccount: 'The account couldn’t be created. Try again',
        orphan: function (email) {
            return (
                'The account ' +
                email +
                ' was created but its profile wasn’t saved. Delete that account, then add this student again'
            );
        }
    };

    var rows = [];
    var nextId = 1;
    var submitted = false;
    var running = false;
    var checked = {};
    var root = null;

    function digits(s) {
        return String(s || '').replace(/\D/g, '');
    }
    function pretty(s) {
        return digits(s).slice(0, 11);
    }

    function tidyName(s) {
        var v = String(s || '')
            .replace(/\s+/g, ' ')
            .trim();
        if (v && (v === v.toLowerCase() || v === v.toUpperCase())) {
            v = v.toLowerCase().replace(/(^|[\s'’-])([a-zñ])/g, function (m, lead, ch) {
                return lead + ch.toUpperCase();
            });
        }
        return v;
    }

    function blankRow(grp) {
        return { id: nextId++, last: '', first: '', mid: '', num: '', grp: grp || '', touched: {} };
    }
    function isBlank(r) {
        return !r.last.trim() && !r.first.trim() && !r.mid.trim() && !digits(r.num);
    }

    function randomPassword() {
        var chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%';
        var bytes = new Uint32Array(20);
        crypto.getRandomValues(bytes);

        return Array.from(bytes, function (b) {
            return chars[b % chars.length];
        }).join('');
    }

    async function createStudent(student) {
        var existing = await sb
            .from('profiles')
            .select('email')
            .eq('email', student.email)
            .maybeSingle();
        if (existing.error) {
            return { status: 'precheck_error', error: existing.error };
        }
        if (existing.data) {
            return { status: 'duplicate' };
        }

        var authRes = await sb.rpc('admin_create_auth_user', {
            target_email: student.email,
            default_password: randomPassword()
        });
        if (authRes.error) {
            return { status: 'auth_error', error: authRes.error };
        }

        var insertRes = await sb.from('profiles').insert([
            {
                full_name: student.fullName,
                email: student.email,
                section: student.section,
                group_type: student.groupType,
                parental_consent: true,
                student_assent: true,
                max_devices: 1,
                status: 'inactive',
                role: 'student'
            }
        ]);
        if (insertRes.error) {
            return { status: 'profile_error', error: insertRes.error };
        }
        return { status: 'created' };
    }

    function problems(r, index) {
        if (isBlank(r)) {
            return [];
        }
        var out = [];
        if (!r.last.trim()) {
            out.push({ field: 'last', text: MSG.last });
        }
        if (!r.first.trim()) {
            out.push({ field: 'first', text: MSG.first });
        }
        if (!r.grp) {
            out.push({ field: 'grp', text: MSG.group });
        }
        var d = digits(r.num);
        if (!d) {
            out.push({ field: 'num', text: MSG.numEmpty });
        } else if (d.length !== 11) {
            out.push({ field: 'num', text: MSG.numLength });
        } else {
            var taken = checked[d];
            if (taken) {
                out.push({ field: 'num', text: MSG.numTaken(taken.name || 'Another student') });
            }
            for (var j = 0; j < index; j++) {
                if (digits(rows[j].num) === d) {
                    out.push({ field: 'num', text: MSG.numTwice(j + 1) });
                    break;
                }
            }
        }
        return out;
    }

    function ready(r, index) {
        if (isBlank(r)) {
            return false;
        }
        if (problems(r, index).length) {
            return false;
        }
        var d = digits(r.num);
        return Object.prototype.hasOwnProperty.call(checked, d);
    }

    function visible(r, index) {
        return problems(r, index).filter(function (p) {
            return submitted || r.touched[p.field];
        });
    }

    function build() {
        if ($('#modal-add-students')) {
            return;
        }
        var overlay = document.createElement('div');
        overlay.className = 'overlay';
        overlay.id = 'modal-add-students';
        overlay.setAttribute('role', 'dialog');
        overlay.setAttribute('aria-modal', 'true');
        overlay.setAttribute('aria-labelledby', 'as-title');
        overlay.innerHTML =
            '<div class="modal modal-xl">' +
            '<header class="modal-head"><div class="modal-head-text"><h2 class="modal-title" id="as-title">Add students</h2>' +
            '<p class="muted">One row per student.</p></div></header>' +
            '<div class="modal-body"><form id="as-form" novalidate>' +
            '<div class="form-grid" style="grid-template-columns:repeat(2,minmax(0,1fr));gap:16px;margin-bottom:16px">' +
            '<div class="field" id="as-section-field"><label class="label" for="as-section">Section <span class="req">*</span></label>' +
            '<select class="select" id="as-section" data-section-select aria-describedby="as-section-msg"></select>' +
            '<p class="field-msg" id="as-section-msg"></p></div>' +
            '</div>' +
            '<div class="as-addbar">' +
            '<button type="button" class="btn btn-secondary btn-sm" id="as-add">' +
            '<svg class="icon"><use href="#i-plus"></use></svg> Add</button>' +
            '<input class="input" id="as-count" type="number" inputmode="numeric" min="1" max="50" value="1" aria-label="How many rows to add">' +
            '<span class="muted">rows</span>' +
            '</div>' +
            '<div id="as-grid" class="as-table" role="group" aria-label="Students"></div>' +
            '</form></div>' +
            '<footer class="modal-foot">' +
            '<div class="as-foot-msg"><p class="field-msg" id="as-summary" role="alert" tabindex="-1"></p>' +
            '<button type="button" class="as-status" id="as-status" hidden></button></div>' +
            '<button type="button" class="btn btn-secondary" data-modal-close>Cancel</button>' +
            '<button type="submit" class="btn btn-primary" form="as-form" id="as-submit">Add students</button>' +
            '</footer></div>';
        document.body.appendChild(overlay);
        root = overlay;

        var ask = document.createElement('div');
        ask.className = 'overlay';
        ask.id = 'modal-as-draft';
        ask.setAttribute('role', 'dialog');
        ask.setAttribute('aria-modal', 'true');
        ask.setAttribute('aria-labelledby', 'as-draft-title');
        ask.innerHTML =
            '<div class="modal modal-sm">' +
            '<header class="modal-head"><div class="modal-head-text"><h2 class="modal-title" id="as-draft-title">You have unsaved changes</h2></div></header>' +
            '<div class="modal-body"><p class="draft-text">Save them as a draft to continue later, or discard them.</p></div>' +
            '<footer class="modal-foot">' +
            '<button type="button" class="btn btn-secondary" id="as-draft-discard">Discard</button>' +
            '<button type="button" class="btn btn-primary" id="as-draft-save">Save draft</button>' +
            '</footer></div>';
        document.body.appendChild(ask);
        wire();
    }


    function headRow() {
        return (
            '<div class="as-head as-cells" aria-hidden="true">' +
            '<span>Last name <span class="req">*</span></span><span>First name <span class="req">*</span></span>' +
            '<span>Middle name</span><span>Student number <span class="req">*</span></span><span>Condition <span class="req">*</span></span><span></span></div>'
        );
    }

    function drawGrid(focus) {
        var html = headRow();
        rows.forEach(function (r, i) {
            html +=
                '<div data-row="' +
                r.id +
                '" class="as-row"><div class="as-cells">' +
                FIELDS.map(function (f) {
                    var label = {
                        last: 'Last name',
                        first: 'First name',
                        mid: 'Middle name',
                        num: 'Student number'
                    }[f];
                    if (f === 'grp') {
                        return (
                            '<select class="select" data-f="grp" aria-label="Condition, row ' +
                            (i + 1) +
                            '" aria-describedby="as-msg-' +
                            r.id +
                            '"><option value="">Choose\u2026</option>' +
                            GROUPS.map(function (g) {
                                return (
                                    '<option value="' +
                                    g[0] +
                                    '"' +
                                    (r.grp === g[0] ? ' selected' : '') +
                                    '>' +
                                    esc(g[1]) +
                                    '</option>'
                                );
                            }).join('') +
                            '</select>'
                        );
                    }
                    return (
                        '<input class="input" type="text" data-f="' +
                        f +
                        '" value="' +
                        esc(r[f]) +
                        '" autocomplete="off" ' +
                        (f === 'num'
                            ? 'inputmode="numeric" maxlength="11" placeholder="11 digits" '
                            : 'spellcheck="false" ') +
                        'aria-label="' +
                        label +
                        ', row ' +
                        (i + 1) +
                        '" aria-describedby="as-msg-' +
                        r.id +
                        '">'
                    );
                }).join('') +
                '<button type="button" class="btn btn-ghost btn-sm" data-del="' +
                r.id +
                '" aria-label="Remove row ' +
                (i + 1) +
                '">' +
                '<svg class="icon"><use href="#i-trash"></use></svg></button></div>' +
                '<p class="field-msg" id="as-msg-' +
                r.id +
                '"></p></div>';
        });
        $('#as-grid').innerHTML = html;
        rows.forEach(function (r, i) {
            paintRow(i);
        });
        paintButton();
        if (focus) {
            goTo(focus.id, focus.f);
        }
    }

    function rowEl(id) {
        return $('[data-row="' + id + '"]', root);
    }

    // the row messages stay hidden in the table; the first one (and how many more) shows in the footer
    function paintStatus() {
        var bad = $$('.as-row', root).filter(function (el) {
            return $('.field-msg', el).textContent;
        });
        var btn = $('#as-status', root);
        if (!bad.length) {
            btn.hidden = true;
            btn.textContent = '';
            return;
        }
        var first = bad[0];
        var n = indexOfRow(Number(first.getAttribute('data-row'))) + 1;
        btn.textContent =
            'Row ' +
            n +
            ' \u00b7 ' +
            $('.field-msg', first).textContent +
            (bad.length > 1 ? ' (+' + (bad.length - 1) + ' more)' : '');
        btn.setAttribute('data-go', first.getAttribute('data-row'));
        btn.hidden = false;
    }

    function paintRow(i, quiet) {
        var r = rows[i];
        var el = rowEl(r.id);
        if (!el) {
            return;
        }
        var msg = $('.field-msg', el);

        var shown = quiet && !msg.textContent ? [] : visible(r, i);
        if (!(quiet && !msg.textContent)) {
            msg.textContent = shown.length ? shown[0].text : '';
        }
        FIELDS.forEach(function (f) {
            var input = $('[data-f="' + f + '"]', el);
            var bad = shown.some(function (p) {
                return p.field === f;
            });
            if (bad) {
                input.setAttribute('aria-invalid', 'true');
            } else {
                input.removeAttribute('aria-invalid');
            }
        });
        paintStatus();
    }

    function paintAll() {
        rows.forEach(function (_, i) {
            paintRow(i);
        });
        paintButton();
    }

    function paintButton() {
        var n = rows.filter(function (r, i) {
            return ready(r, i);
        }).length;
        var filled = rows.filter(function (r) {
            return !isBlank(r);
        }).length;
        var count = n || filled;
        var where = sectionName() ? ' to ' + sectionName() : '';
        $('#as-submit').textContent = count
            ? (count === 1 ? 'Add 1 student' : 'Add ' + count + ' students') + where
            : 'Add students';
    }

    function sectionName() {
        var select = $('#as-section');
        return select && select.value ? select.value : '';
    }

    function paintContext() {
        var name = sectionName();
        $('#as-title').textContent = name ? 'Add students to ' + name : 'Add students';
        paintButton();
    }

    function goTo(id, f) {
        var el = rowEl(id);
        var input = el && $('[data-f="' + f + '"]', el);
        if (input) {
            input.focus();
        }
    }

    async function checkNumbers() {
        var wanted = [];
        rows.forEach(function (r) {
            var d = digits(r.num);
            if (
                d.length === 11 &&
                !Object.prototype.hasOwnProperty.call(checked, d) &&
                wanted.indexOf(d) === -1
            ) {
                wanted.push(d);
            }
        });
        if (!wanted.length) {
            return true;
        }
        var res = await sb.rpc('admin_numbers_taken', { p_numbers: wanted });
        if (res.error) {
            return false;
        }
        wanted.forEach(function (d) {
            checked[d] = null;
        });
        (res.data || []).forEach(function (t) {
            checked[String(t.number_key)] = { name: t.full_name ? tidyName(t.full_name) : t.email };
        });
        return true;
    }

    function indexOfRow(id) {
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].id === id) {
                return i;
            }
        }
        return -1;
    }

    var draft = null;

    function hasContent() {
        return rows.some(function (r) {
            return !isBlank(r);
        });
    }

    function restoreDraft() {
        if (!draft) {
            return;
        }
        rows = draft;
        draft = null;
        drawGrid();
        if (window.PIAAdmin && window.PIAAdmin.toastOk) {
            window.PIAAdmin.toastOk('Draft restored', 'Your unsaved students are back.');
        }
    }

    function closeAdd() {
        rows = [blankRow()];
        var close = $('[data-modal-close]', root);
        if (close) {
            close.click();
        }
    }

    // closing with students typed in asks first: save a draft, discard, or keep editing
    function wireDraft() {
        function guard(event) {
            if (!hasContent()) {
                return;
            }
            event.stopImmediatePropagation();
            event.preventDefault();
            window.PIAAdmin.openModal('modal-as-draft');
        }
        root.addEventListener(
            'click',
            function (event) {
                if (event.target.closest('[data-modal-close]')) {
                    guard(event);
                }
            },
            true
        );
        root.addEventListener(
            'mousedown',
            function (event) {
                if (event.target === root) {
                    guard(event);
                }
            },
            true
        );
        document.addEventListener(
            'keydown',
            function (event) {
                var layers = window.PIAAdmin.openLayers;
                if (event.key === 'Escape' && layers[layers.length - 1] === root) {
                    guard(event);
                }
            },
            true
        );
        $('#as-draft-save').addEventListener('click', function () {
            draft = rows;
            window.PIAAdmin.closeModal('modal-as-draft');
            closeAdd();
        });
        $('#as-draft-discard').addEventListener('click', function () {
            draft = null;
            window.PIAAdmin.closeModal('modal-as-draft');
            closeAdd();
        });
    }

    function wire() {
        var grid = $('#as-grid', root);

        // the custom dropdown fires 'change' only, so listen to both
        function onEdit(event) {
            var item = event.target.closest('[data-row]');
            if (!item) {
                return;
            }
            var i = indexOfRow(Number(item.getAttribute('data-row')));
            var f = event.target.getAttribute('data-f');
            if (f === 'num') {
                event.target.value = pretty(event.target.value);
            }
            rows[i][f] = event.target.value;
            paintRow(i, true);
            paintButton();
        }
        grid.addEventListener('input', onEdit);
        grid.addEventListener('change', onEdit);

        grid.addEventListener('focusout', async function (event) {
            var f = event.target.getAttribute && event.target.getAttribute('data-f');
            var item = event.target.closest && event.target.closest('[data-row]');
            if (!f || !item) {
                return;
            }
            var i = indexOfRow(Number(item.getAttribute('data-row')));
            if (i < 0) {
                return;
            }
            if (f !== 'num' && f !== 'grp') {
                var tidy = tidyName(event.target.value);
                event.target.value = tidy;
                rows[i][f] = tidy;
            }
            if (f === 'grp' || !isBlank(rows[i]) || rows[i].touched[f]) {
                rows[i].touched[f] = true;
            }
            paintRow(i);
            if (f === 'num' && digits(rows[i].num).length === 11) {
                var ok = await checkNumbers();
                if (!ok) {
                    $('#as-summary').textContent = MSG.cantCheck;
                }
                paintAll();
            }
        });

        grid.addEventListener('keydown', function (event) {
            var item = event.target.closest('[data-row]');
            if (!item) {
                return;
            }
            var id = Number(item.getAttribute('data-row'));
            var i = indexOfRow(id);
            var f = event.target.getAttribute('data-f');
            var k = FIELDS.indexOf(f);
            if (event.key === 'Enter' && k >= 0 && f !== 'grp') {
                event.preventDefault();
                if (k < FIELDS.length - 2) {
                    goTo(id, FIELDS[k + 1]);
                } else if (i === rows.length - 1) {
                    rows.push(blankRow(rows[i].grp));
                    drawGrid({ id: rows[rows.length - 1].id, f: 'last' });
                } else {
                    goTo(rows[i + 1].id, 'last');
                }
            } else if (f === 'grp') {
                return;
            } else if (event.key === 'ArrowDown' && i < rows.length - 1) {
                event.preventDefault();
                goTo(rows[i + 1].id, f);
            } else if (event.key === 'ArrowUp' && i > 0) {
                event.preventDefault();
                goTo(rows[i - 1].id, f);
            }
        });

        grid.addEventListener('click', function (event) {
            var del = event.target.closest('[data-del]');
            if (!del) {
                return;
            }
            rows.splice(indexOfRow(Number(del.getAttribute('data-del'))), 1);
            if (!rows.length) {
                rows.push(blankRow());
            }
            drawGrid();
        });

        $('#as-add', root).addEventListener('click', function () {
            var n = Math.max(1, Math.min(50, parseInt($('#as-count', root).value, 10) || 1));
            var first = null;
            for (var k = 0; k < n && rows.length < 100; k++) {
                rows.push(blankRow(rows[rows.length - 1].grp));
                first = first || rows[rows.length - 1];
            }
            drawGrid(first && { id: first.id, f: 'last' });
        });
        $('#as-section', root).addEventListener('change', function () {
            $('#as-section-msg').textContent = '';
            paintContext();
        });
        wireDraft();
        $('#as-status', root).addEventListener('click', function (event) {
            var row = rowEl(Number(event.currentTarget.getAttribute('data-go')));
            var field = row && $('[aria-invalid="true"]', row);
            if (field && field.focus) {
                field.focus();
            }
        });
        $('#as-form', root).addEventListener('submit', submit);
    }

    function clearMessages() {
        ['#as-summary', '#as-section-msg'].forEach(
            function (s) {
                $(s).textContent = '';
            }
        );
    }

    async function submit(event) {
        event.preventDefault();
        if (running) {
            return;
        }
        running = true;
        submitted = true;
        clearMessages();
        var button = $('#as-submit');
        var label = button.textContent;
        button.disabled = true;
        try {
            var section = $('#as-section').value;
            var bad = false;
            if (!section) {
                $('#as-section-msg').textContent = MSG.section;
                bad = true;
            }

            if (
                !rows.some(function (r) {
                    return !isBlank(r);
                })
            ) {
                $('#as-summary').textContent = MSG.nobody;
                return;
            }
            var asked = await checkNumbers();
            if (!asked) {
                $('#as-summary').textContent = MSG.cantCheck;
                return;
            }
            paintAll();

            var wrong = rows.filter(function (r, i) {
                return !isBlank(r) && problems(r, i).length;
            });
            if (wrong.length) {
                $('#as-summary').textContent = MSG.problem + '. ' + MSG.fixRows(wrong.length);
                bad = true;
            }
            if (bad) {
                if (wrong.length) {
                    var first = wrong[0];
                    goTo(first.id, problems(first, indexOfRow(first.id))[0].field);
                } else {
                    $('#as-summary').focus();
                }
                return;
            }

            var todo = rows.filter(function (r) {
                return !isBlank(r);
            });
            var done = 0;
            var failed = [];
            for (var n = 0; n < todo.length; n++) {
                var r = todo[n];
                button.textContent = 'Adding ' + (n + 1) + ' of ' + todo.length + '…';
                var d = digits(r.num);
                var fullName = [r.first.trim(), r.mid.trim(), r.last.trim()]
                    .filter(Boolean)
                    .join(' ');
                var email = d + '@' + INTERNAL_DOMAIN;
                var enroll = (window.PIAAdmin && window.PIAAdmin.enrollOne) || createStudent;
                var result = await enroll({
                    email: email,
                    fullName: fullName,
                    section: section,
                    groupType: r.grp
                });
                var reason = '';
                if (result.status === 'created') {
                    var saved = await sb.rpc('admin_set_student_number', {
                        p_email: email,
                        p_number: d
                    });
                    if (saved.error) {
                        reason =
                            MSG.notAdded(fullName) +
                            '. ' +
                            String(saved.error.message || '').replace(/^PIA:\s*/, '');
                    }
                } else if (result.status === 'duplicate') {
                    reason = MSG.exists;
                } else if (result.status === 'profile_error') {
                    reason = MSG.orphan(email);
                } else {
                    reason = MSG.noAccount;
                }
                if (reason) {
                    failed.push({ row: r, reason: reason });
                } else {
                    done++;
                    r.done = true;
                }
            }

            rows = rows.filter(function (r) {
                return !r.done;
            });
            if (window.PIAAdmin && window.PIAAdmin.refreshAll) {
                window.PIAAdmin.refreshAll();
            }
            if (done) {
                document.dispatchEvent(new CustomEvent('pia:students-added'));
            }
            if (!failed.length) {
                if (window.PIAAdmin && window.PIAAdmin.toastOk) {
                    window.PIAAdmin.toastOk(MSG.added(done) + ' to ' + section, '');
                }
                var close = $('[data-modal-close]', root);
                if (close) {
                    close.click();
                }
                return;
            }
            if (!rows.length) {
                rows.push(blankRow());
            }
            drawGrid();
            failed.forEach(function (f) {
                var el = rowEl(f.row.id);
                if (!el) {
                    return;
                }
                $('.field-msg', el).textContent = f.reason;
            });
            $('#as-summary').textContent =
                (done ? MSG.added(done) + ' to ' + section + '. ' : '') +
                (failed.length === 1
                    ? '1 student wasn\u2019t added: see the message under their row.'
                    : failed.length +
                      ' students weren\u2019t added: see the message under each row.');
            $('#as-summary').focus();
        } finally {
            running = false;
            button.disabled = false;
            paintButton();
            if (button.textContent.indexOf('Adding') === 0) {
                button.textContent = label;
            }
        }
    }

    function reset() {
        rows = [];
        for (var k = 0; k < START_ROWS; k++) {
            rows.push(blankRow());
        }
        submitted = false;
        checked = {};
        clearMessages();
        var section = $('#as-section');
        if (!section.querySelector('option[value=""]')) {
            section.insertBefore(new Option('Choose a section', ''), section.firstChild);
        }

        var filter = $('#section-filter');
        var wanted = filter ? filter.value : '';
        var known = !!(
            wanted && section.querySelector('option[value="' + wanted.replace(/"/g, '') + '"]')
        );
        section.value = known ? wanted : '';

        $('#as-section-field').hidden = known;
        restoreDraft();
        paintContext();
        drawGrid({ id: rows[0].id, f: 'last' });
    }

    function init() {
        build();

        var wasOpen = false;
        new MutationObserver(function () {
            var open = root.classList.contains('is-mounted');
            if (open && !wasOpen) {
                reset();
            }
            wasOpen = open;
        }).observe(root, { attributes: true, attributeFilter: ['class'] });
    }

    if (document.body) {
        init();
    } else {
        document.addEventListener('DOMContentLoaded', init);
    }
})();
