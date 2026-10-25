/*
 * Student forms.
 * Add one student, add many students, and edit a student.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function tutorName(key) {
        var t = Admin.TUTORS.filter(function (x) {
            return x.key === key;
        })[0];
        return t ? t.name : key || '';
    }

    function fillTutorSelect(select) {
        select.innerHTML = '';
        var none = document.createElement('option');
        none.value = '';
        none.textContent = 'Not assigned yet';
        select.appendChild(none);
        Admin.TUTORS.forEach(function (t) {
            var opt = document.createElement('option');
            opt.value = t.key;
            opt.textContent = t.name;
            select.appendChild(opt);
        });
    }

    function tutorLabel(s) {
        if (s.selected_character) {
            return tutorName(s.selected_character);
        }
        if (s.group_type === 'assigned') {
            return s.is_ocean_done ? 'No character saved' : 'Assigned after OCEAN';
        }
        if (s.group_type === 'non-assigned') {
            return 'Not chosen yet';
        }
        if (s.group_type === 'neutral') {
            return tutorName('pia-neutral');
        }
        return '—';
    }
    Admin.tutorLabel = tutorLabel;

    function syncTutorField(prefix) {
        var group = ($('input[name="' + prefix + '-condition"]:checked') || {}).value;
        var select = $('#' + prefix + '-tutor');
        var held = select.getAttribute('data-initial') || '';
        var assigned = group === 'assigned',
            neutral = group === 'neutral';
        $('#' + prefix + '-tutor-field').hidden = !(assigned || neutral || held);
        select.disabled = true;
        if (neutral) {
            select.value = 'pia-neutral';
        } else if (held) {
            select.value = held;
        } else {
            select.value = '';
        }
        $('#' + prefix + '-tutor-hint').textContent = neutral
            ? 'Always the Neutral tutor. The student goes from OCEAN to the tutoring dashboard and the game as an Assigned student would, but the OCEAN result does not choose the tutor.'
            : assigned
              ? 'Automatically assigned from the OCEAN result when the student finishes the questionnaire. Tied highest traits are resolved by the system.'
              : 'Kept as it is. Only Assigned and Neutral students are given a tutor here; changing the group does not clear this.';
    }

    function initTutorFields() {
        ['rs', 'es'].forEach(function (prefix) {
            fillTutorSelect($('#' + prefix + '-tutor'));
            $$('input[name="' + prefix + '-condition"]').forEach(function (radio) {
                radio.addEventListener('change', function () {
                    syncTutorField(prefix);
                });
            });
            syncTutorField(prefix);
        });
        $('#register-student-form').addEventListener('reset', function () {
            setTimeout(function () {
                $('#rs-tutor').value = '';
                syncTutorField('rs');
            }, 0);
        });
    }
    Admin.initTutorFields = initTutorFields;

    async function handleRegisterStudent(event) {
        event.preventDefault();
        Admin.clearFormErrors('register-student-form');

        var first = $('#rs-first').value.trim();
        var middle = $('#rs-middle').value.trim();
        var last = $('#rs-last').value.trim();
        var email = Admin.normalizeEmail($('#rs-email').value);
        var section = $('#rs-section').value;
        var groupType = ($('input[name="rs-condition"]:checked') || {}).value;

        var valid = true;
        valid = Admin.setFieldError('rs-first', first ? '' : 'First name is required.') && valid;
        valid = Admin.setFieldError('rs-last', last ? '' : 'Last name is required.') && valid;
        valid =
            Admin.setFieldError(
                'rs-email',
                Admin.isEmail(email) ? '' : 'Enter a valid school email address.'
            ) && valid;
        valid =
            Admin.setFieldError('rs-section', section ? '' : 'Create a section first.') && valid;
        var number = ($('#rs-number').value || '').replace(/\D/g, '');
        valid =
            Admin.setFieldError(
                'rs-number',
                number.length === 11 ? '' : 'Enter the 11-digit student number.'
            ) && valid;

        valid =
            Admin.setFieldError(
                'rs-consent',
                $('#rs-consent').checked ? '' : 'Parental consent must be recorded first.'
            ) && valid;
        valid =
            Admin.setFieldError(
                'rs-assent',
                $('#rs-assent').checked ? '' : 'Student assent must be recorded first.'
            ) && valid;
        if (!valid) {
            return;
        }

        var fullName = [first, middle, last].filter(Boolean).join(' ');
        var release = Admin.setBusy($('#rs-submit'), 'Registering…');

        try {
            var result = await enrollOneStudent({
                email: email,
                fullName: fullName,
                section: section,
                groupType: groupType
            });

            if (result.status === 'precheck_error') {
                Admin.toastErr(
                    'Registration stopped',
                    Admin.isMissingColumn(result.error)
                        ? Admin.MIGRATION_MISSING
                        : Admin.friendlyDbError(
                              result.error,
                              'Could not check the roster for this email.'
                          )
                );
                return;
            }
            if (result.status === 'duplicate') {
                Admin.setFieldError('rs-email', 'This email is already on the roster.');
                Admin.toastErr('Duplicate email', email + ' already has an account.');
                return;
            }
            if (result.status === 'auth_error') {
                Admin.toastErr(
                    'Auth user not created',
                    Admin.friendlyDbError(result.error, 'Could not create the auth user.')
                );
                return;
            }
            if (result.status === 'profile_error') {
                Admin.showNotice(
                    'Registration incomplete',
                    Admin.friendlyDbError(result.error, 'Could not save the profile.') +
                        '\n\nAn auth user was already created for ' +
                        email +
                        '. It must be deleted before registering this student again.',
                    'danger'
                );
                return;
            }

            Admin.closeModal('modal-register-student');
            $('#register-student-form').reset();
            Admin.clearFormErrors('register-student-form');

            Admin.toastOk(
                'Student registered',
                fullName + ' is on the roster, inactive until they use the activation link.'
            );
            var savedNumber = window.PIACheckin
                ? await window.PIACheckin.saveNumberFor(email, number)
                : { ok: false, message: 'Student numbers are not available.' };
            if (!savedNumber.ok) {
                Admin.toastErr(
                    'Student number not saved',
                    savedNumber.message + ' Add it from the Student number column.'
                );
            }
            Admin.refreshAll();
        } finally {
            release();
        }
    }
    Admin.handleRegisterStudent = handleRegisterStudent;

    async function enrollOneStudent(student) {
        var existing = await sb
            .from('profiles')
            .select('email' + Admin.CONSENT_COLUMNS)
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
            default_password: Admin.generateSecurePassword()
        });
        if (authRes.error) {
            return { status: 'auth_error', error: authRes.error };
        }

        var newRow = {
            full_name: student.fullName,
            email: student.email,
            section: student.section,
            group_type: student.groupType,
            parental_consent: true,
            student_assent: true,
            max_devices: 1,
            status: 'inactive',
            role: 'student'
        };
        var insertRes = await sb.from('profiles').insert([newRow]);
        if (insertRes.error) {
            return { status: 'profile_error', error: insertRes.error };
        }

        return { status: 'created' };
    }

    var BN_GROUPS = [
        { value: 'assigned', label: 'EXP · Assigned persona', short: 'Assigned' },
        { value: 'non-assigned', label: 'EXP · Free choice', short: 'Free choice' },
        { value: 'neutral', label: 'EXP · Neutral persona', short: 'Neutral' },
        { value: 'control', label: 'CTRL · Traditional', short: 'Control' }
    ];

    var BN_DOMAIN = 'ue.edu.ph';

    var bn = {
        rows: [],
        nextId: 1,
        running: false,
        defaultGroup: '',
        step: 1,
        selectIds: [],
        section: ''
    };

    function bnTitleCase(word) {
        return word.toLowerCase().replace(/(^|[\s'’-])([a-zñ])/g, function (m, lead, letter) {
            return lead + letter.toUpperCase();
        });
    }

    function guessNames(email) {
        var at = email.lastIndexOf('@');
        var local = at > 0 ? email.slice(0, at) : email;
        var domain = at > 0 ? email.slice(at + 1) : '';
        var out = { name: '', check: '' };

        if (domain !== BN_DOMAIN) {
            out.check = 'Not a ' + BN_DOMAIN + ' address. Type the name.';
            return out;
        }
        var parts = local.split('.');
        if (parts.length < 2 || !parts[0] || !parts[1]) {
            out.check = 'The email is not lastname.firstname. Type the name.';
            return out;
        }
        if (parts.length > 2) {
            out.name = bnTitleCase(parts.slice(1).join(' ') + ' ' + parts[0]);
            out.check = 'The email has more than one dot. Check the name.';
            return out;
        }

        out.name = bnTitleCase(parts[1]) + ' ' + bnTitleCase(parts[0]);

        if (/\d/.test(local)) {
            out.check = 'The email has a number in it. Check the name.';
        } else if (
            /^(jr|sr|ii|iii|iv)$/.test(parts[1]) ||
            (/(jr|sr|iii)$/.test(parts[1]) && parts[1].length > 4)
        ) {
            out.check = 'May include a suffix such as Jr. Check the name.';
        } else if (/^(dela|delos|delas|santa|van|von)[a-z]{3,}$/.test(parts[0])) {
            out.check = 'The surname may be two words (for example Dela Cruz). Check it.';
        } else if (parts[1].length >= 10 || parts[0].length >= 12) {
            out.check = 'A long name that may be two words. Check it.';
        }
        return out;
    }

    function bnAddRow(fields) {
        var row = {
            id: bn.nextId++,
            name: '',
            email: '',
            group: bn.defaultGroup,
            check: '',
            confirmed: false,
            touched: false
        };
        Object.keys(fields || {}).forEach(function (key) {
            row[key] = fields[key];
        });
        bn.rows.push(row);
        return row;
    }

    function bnRowById(id) {
        return bn.rows.filter(function (row) {
            return row.id === id;
        })[0];
    }

    function bnCleanName(row) {
        return row.name.trim().replace(/\s+/g, ' ');
    }

    function bnStates(ignoreGroup) {
        var counts = {};
        bn.rows.forEach(function (row) {
            counts[row.email] = (counts[row.email] || 0) + 1;
        });
        var onRoster = {};
        (Admin.state.cohort || []).forEach(function (s) {
            onRoster[Admin.normalizeEmail(s.email)] = true;
        });

        return bn.rows.map(function (row) {
            if (bnCleanName(row).split(' ').filter(Boolean).length < 2) {
                return { kind: 'error', text: 'Enter a first and a last name.' };
            }
            if (!Admin.isEmail(row.email)) {
                return { kind: 'error', text: 'Enter a valid school email address.' };
            }
            if (counts[row.email] > 1) {
                return { kind: 'error', text: 'This email is in the list more than once.' };
            }
            if (onRoster[row.email]) {
                return { kind: 'error', text: 'Already on the roster.' };
            }
            if (row.check && !row.confirmed) {
                return { kind: 'check', text: row.check };
            }
            if (!ignoreGroup && !row.group) {
                return { kind: 'error', text: 'Choose a condition.' };
            }
            return { kind: 'ready', text: '' };
        });
    }

    function bnStatusHtml(row, st) {
        if (st.kind === 'ready') {
            return '<span class="badge badge-accent">Ready</span>';
        }
        if (st.kind === 'check') {
            return (
                '<span class="badge badge-warn">Check</span> ' +
                '<button type="button" class="btn btn-ghost btn-sm" data-bn-confirm="' +
                row.id +
                '">Looks right</button>'
            );
        }
        return '<span class="badge badge-danger">Fix</span>';
    }

    function bnPaint() {
        var states = bnStates();
        var ready = 0,
            check = 0,
            fix = 0;
        bn.rows.forEach(function (row, index) {
            var st = states[index];
            if (st.kind === 'ready') {
                ready++;
            } else if (st.kind === 'check') {
                check++;
            } else {
                fix++;
            }
            var cell = $('[data-bn-row="' + row.id + '"] [data-bn-status]');
            if (cell) {
                cell.innerHTML = bnStatusHtml(row, st);
            }
            var note = $('[data-bn-row="' + row.id + '"] [data-bn-note]');
            if (note) {
                note.textContent = st.kind === 'ready' ? '' : st.text;
                note.className = 'bn-note' + (st.kind === 'error' ? ' bn-note-fix' : '');
            }
        });

        var n = bn.rows.length;
        $('#bn-review-title').textContent =
            (bn.section ? bn.section + ' · ' : '') + n + (n === 1 ? ' student' : ' students');
        var issues = [];
        if (check) {
            issues.push(check + ' to check');
        }
        if (fix) {
            issues.push(fix + ' to fix');
        }
        $('#bn-issues').textContent =
            n === 0 ? '' : issues.length ? issues.join(' · ') : 'All ready';
        $('#bn-issues').classList.toggle('is-ok', n > 0 && !issues.length);

        var tally = BN_GROUPS.map(function (g) {
            var count = bn.rows.filter(function (row) {
                return row.group === g.value;
            }).length;
            return count ? g.short + ' ' + count : '';
        }).filter(Boolean);
        $('#bn-summary').textContent = tally.join(' · ');

        var allReady = n > 0 && ready === n;
        $('#bn-submit').disabled = bn.running || !allReady;
        $('#bn-submit-label').textContent =
            n > 0 ? 'Enroll ' + n + (n === 1 ? ' student' : ' students') : 'Enroll students';
    }

    function bnRender() {
        var groupOptions =
            '<option value="">Choose…</option>' +
            BN_GROUPS.map(function (g) {
                return '<option value="' + g.value + '">' + Admin.esc(g.short) + '</option>';
            }).join('');

        (bn.selectIds || []).forEach(function (id) {
            if (Admin.customSelects[id]) {
                Admin.customSelects[id].destroy();
            }
        });
        bn.selectIds = bn.rows.map(function (row) {
            return 'bn-group-' + row.id;
        });

        $('#bn-tbody').innerHTML = bn.rows
            .map(function (row, index) {
                var n = index + 1;
                return (
                    '<tr data-bn-row="' +
                    row.id +
                    '">' +
                    '<td><input class="input input-sm" data-bn-field="name" value="' +
                    Admin.esc(row.name) +
                    '" autocomplete="off" aria-label="Full name, row ' +
                    n +
                    '"></td>' +
                    '<td><span class="bn-email-text">' +
                    Admin.esc(row.email) +
                    '</span><div class="bn-note" data-bn-note></div></td>' +
                    '<td><span class="sr-only" id="bn-group-' +
                    row.id +
                    '-label">Condition, row ' +
                    n +
                    '</span>' +
                    '<select class="input input-sm" id="bn-group-' +
                    row.id +
                    '" data-bn-field="group">' +
                    groupOptions.replace(
                        'value="' + row.group + '"',
                        'value="' + row.group + '" selected'
                    ) +
                    '</select></td>' +
                    '<td data-bn-status></td>' +
                    '<td><button type="button" class="btn btn-ghost btn-sm bn-remove" data-bn-remove="' +
                    row.id +
                    '" aria-label="Remove ' +
                    Admin.esc(row.email) +
                    '" title="Remove this student">&times;</button></td>' +
                    '</tr>'
                );
            })
            .join('');
        bn.selectIds.forEach(Admin.initCustomSelect);
        $('#bn-table')
            .closest('.table-wrap')
            .classList.toggle('is-hidden', bn.rows.length === 0);
        bnPaint();
    }

    function bnShowStep(step) {
        bn.step = step;
        $('#bn-step-add').classList.toggle('is-hidden', step !== 1);
        $('#bn-step-review').classList.toggle('is-hidden', step !== 2);
        $('#bn-continue').classList.toggle('is-hidden', step !== 1);
        $('#bn-submit').classList.toggle('is-hidden', step !== 2);
        $('#bn-consent-wrap').classList.toggle('is-hidden', step !== 2);
        $('#bn-step-label').textContent = step === 1 ? 'Step 1 of 2 · Add' : 'Step 2 of 2 · Review';
    }

    function bnReset() {
        if (bn.running) {
            return;
        }
        bn.rows = [];
        bn.nextId = 1;
        bn.defaultGroup = '';
        bn.section = '';
        $('#bn-emails').value = '';
        $('#bn-apply-group').value = '';
        Admin.refreshCustomSelect('bn-apply-group');
        $('#bn-consent').checked = false;
        $('#bn-add-msg').textContent = '';
        $('#bn-cancel').textContent = 'Cancel';
        var report = $('#bn-report');
        report.classList.add('is-hidden');
        report.innerHTML = '';
        Admin.clearFormErrors('enroll-students-form');
        bnShowStep(1);
        bnRender();
    }

    function bnContinue() {
        $('#bn-add-msg').textContent = '';
        var section = $('#bn-section').value;
        if (!Admin.setFieldError('bn-section', section ? '' : 'Create a section first.')) {
            return;
        }
        bn.section = section;

        var found = ($('#bn-emails').value.match(/[^\s,;<>"']+@[^\s,;<>"']+/g) || []).map(
            Admin.normalizeEmail
        );
        var have = {};
        bn.rows.forEach(function (row) {
            have[row.email] = true;
        });
        found.forEach(function (email) {
            if (have[email]) {
                return;
            }
            have[email] = true;
            var guess = guessNames(email);
            bnAddRow({ email: email, name: guess.name, check: guess.check });
        });

        if (!bn.rows.length) {
            $('#bn-add-msg').textContent = found.length
                ? 'Those emails are already in the list.'
                : 'Add at least one school email address.';
            return;
        }

        var states = bnStates(true);
        var order = bn.rows.map(function (row, i) {
            return { row: row, weight: states[i].kind === 'ready' ? 1 : 0, i: i };
        });
        order.sort(function (a, b) {
            return a.weight - b.weight || a.i - b.i;
        });
        bn.rows = order.map(function (item) {
            return item.row;
        });

        $('#bn-emails').value = '';
        bnRender();
        bnShowStep(2);
        var first = $('#bn-tbody [data-bn-field="name"]');
        if (first) {
            first.focus({ preventScroll: true });
        }
    }

    function bnBack() {
        bnShowStep(1);
        var n = bn.rows.length;
        $('#bn-add-msg').textContent =
            n +
            (n === 1 ? ' student is' : ' students are') +
            ' already in the list. Add more emails, or Continue.';
        $('#bn-emails').focus();
    }

    function bnApplyAll() {
        var group = $('#bn-apply-group').value;
        if (!group) {
            return;
        }
        bn.defaultGroup = group;
        bn.rows.forEach(function (row) {
            row.group = group;
        });
        bnRender();
    }

    function bnOnInput(event) {
        var input = event.target.closest('[data-bn-field]');
        if (!input) {
            return;
        }
        var row = bnRowById(Number(input.closest('[data-bn-row]').getAttribute('data-bn-row')));
        if (!row) {
            return;
        }

        if (input.getAttribute('data-bn-field') === 'group') {
            row.group = input.value;
        } else {
            row.name = input.value;
            row.touched = true;
            row.confirmed = true;
        }
        bnPaint();
    }

    function bnOnClick(event) {
        var remove = event.target.closest('[data-bn-remove]');
        if (remove) {
            var id = Number(remove.getAttribute('data-bn-remove'));
            bn.rows = bn.rows.filter(function (row) {
                return row.id !== id;
            });
            bnRender();
            if (!bn.rows.length) {
                bnBack();
            }
            return;
        }
        var confirmBtn = event.target.closest('[data-bn-confirm]');
        if (confirmBtn) {
            var row = bnRowById(Number(confirmBtn.getAttribute('data-bn-confirm')));
            if (row) {
                row.confirmed = true;
                bnPaint();
            }
        }
    }

    function bnFailureText(result) {
        if (result.status === 'duplicate') {
            return 'Already on the roster.';
        }
        if (result.status === 'precheck_error') {
            return Admin.isMissingColumn(result.error)
                ? Admin.MIGRATION_MISSING
                : Admin.friendlyDbError(result.error, 'Could not check the roster for this email.');
        }
        if (result.status === 'auth_error') {
            return (
                'Account not created: ' +
                Admin.friendlyDbError(result.error, 'Could not create the auth user.')
            );
        }
        if (result.status === 'profile_error') {
            return (
                Admin.friendlyDbError(result.error, 'Could not save the profile.') +
                ' An account was already created for this email and must be deleted before it is enrolled again.'
            );
        }
        return result.message || 'Could not enroll this student.';
    }

    async function handleEnrollStudents(event) {
        event.preventDefault();
        if (bn.running || bn.step !== 2) {
            return;
        }
        Admin.clearFormErrors('enroll-students-form');

        var consentOk = Admin.setFieldError(
            'bn-consent',
            $('#bn-consent').checked
                ? ''
                : 'Parental consent and student assent must be recorded first.'
        );
        var states = bnStates();
        if (
            !bn.rows.length ||
            states.some(function (st) {
                return st.kind !== 'ready';
            })
        ) {
            return;
        }
        if (!consentOk) {
            return;
        }

        var section = bn.section;
        bn.running = true;
        $('#bn-cancel').disabled = true;
        $$(
            '#enroll-students-form input, #enroll-students-form select, #enroll-students-form textarea, #enroll-students-form button, #bn-consent'
        ).forEach(function (el) {
            el.disabled = true;
        });
        var release = Admin.setBusy($('#bn-submit'), 'Enrolling…');

        var queue = bn.rows.slice();
        var total = queue.length;
        var created = [];
        var failed = [];

        try {
            for (var i = 0; i < queue.length; i++) {
                var row = queue[i];
                $('#bn-issues').textContent = 'Enrolling ' + (i + 1) + ' of ' + total + '…';
                var result;
                try {
                    result = await enrollOneStudent({
                        email: row.email,
                        fullName: bnCleanName(row),
                        section: section,
                        groupType: row.group
                    });
                } catch (err) {
                    result = { status: 'error', message: (err && err.message) || 'Network error.' };
                }
                if (result.status === 'created') {
                    created.push(row);
                } else {
                    failed.push({ row: row, text: bnFailureText(result) });
                }
            }
        } finally {
            bn.running = false;
            release();
            $('#bn-cancel').disabled = false;
            $$(
                '#enroll-students-form input, #enroll-students-form select, #enroll-students-form textarea, #enroll-students-form button, #bn-consent'
            ).forEach(function (el) {
                el.disabled = false;
            });
        }

        var createdIds = {};
        created.forEach(function (row) {
            createdIds[row.id] = true;
        });
        bn.rows = bn.rows.filter(function (row) {
            return !createdIds[row.id];
        });

        var report = $('#bn-report');
        report.classList.remove('is-hidden');
        report.innerHTML =
            '<p><strong>' +
            created.length +
            ' of ' +
            total +
            ' enrolled' +
            (section ? ' in ' + Admin.esc(section) : '') +
            '.</strong></p>' +
            (failed.length
                ? '<p>' +
                  failed.length +
                  ' not enrolled:</p><ul>' +
                  failed
                      .map(function (f) {
                          return (
                              '<li>' + Admin.esc(f.row.email) + ': ' + Admin.esc(f.text) + '</li>'
                          );
                      })
                      .join('') +
                  '</ul><p>Those students are still in the list. Fix them and enroll again; students already enrolled are skipped.</p>'
                : '<p>Everyone is on the roster, inactive until they use the activation link.</p>');

        if (created.length) {
            Admin.toastOk(
                created.length +
                    (created.length === 1 ? ' student enrolled' : ' students enrolled'),
                failed.length
                    ? failed.length + ' were not enrolled. See the list.'
                    : 'Inactive until they use the activation link.'
            );
            Admin.refreshAll();
        } else if (failed.length) {
            Admin.toastErr('No students enrolled', 'See the list in the dialog.');
        }
        if (!bn.rows.length) {
            $('#bn-cancel').textContent = 'Close';
        }
        bnRender();
    }

    function initEnrollStudents() {
        $('#enroll-students-form').addEventListener('submit', handleEnrollStudents);
        $('#bn-continue').addEventListener('click', bnContinue);
        $('#bn-back').addEventListener('click', bnBack);
        $('#bn-apply-all').addEventListener('click', bnApplyAll);
        $('#bn-tbody').addEventListener('input', bnOnInput);
        $('#bn-tbody').addEventListener('change', bnOnInput);
        $('#bn-tbody').addEventListener('click', bnOnClick);

        $('#enroll-students-form').addEventListener('keydown', function (event) {
            if (event.key === 'Enter' && event.target.tagName === 'INPUT') {
                event.preventDefault();
            }
        });
        $('#bn-consent').addEventListener('change', function () {
            Admin.setFieldError('bn-consent', '');
        });
        Admin.initCustomSelect('bn-section');
        Admin.initCustomSelect('bn-apply-group');
        $$('[data-modal-open="modal-enroll-students"]').forEach(function (button) {
            button.addEventListener('click', bnReset);
        });
        bnReset();
    }
    Admin.initEnrollStudents = initEnrollStudents;

    function openEditStudent(email) {
        var s = Admin.findStudent(email);
        if (!s) {
            return;
        }

        Admin.clearFormErrors('edit-student-form');

        var parts = (s.full_name || '').trim().split(/\s+/);
        var first = parts[0] || '',
            middle = '',
            last = '';
        if (parts.length === 2) {
            last = parts[1];
        } else if (parts.length > 2) {
            last = parts[parts.length - 1];
            middle = parts.slice(1, -1).join(' ');
        }

        $('#es-original-email').value = s.email;
        $('#es-first').value = first;
        $('#es-middle').value = middle;
        $('#es-last').value = last;
        $('#es-email').value = s.email;
        ['pre', 'post'].forEach(function (test) {
            fillScoreField('es-' + test + '-raw', s[test + '_test_raw_score']);
            fillScoreField('es-' + test + '-max', s[test + '_test_max_score']);

            $('#es-' + test + '-result').setAttribute(
                'data-legacy',
                s[test + '_test_score'] != null && s[test + '_test_raw_score'] == null
                    ? Admin.formatScore(s[test + '_test_score'])
                    : ''
            );
            paintScorePreview(test);
        });
        fillConsentBox('es-consent', s.parental_consent);
        fillConsentBox('es-assent', s.student_assent);

        var sectionSelect = $('#es-section');
        var known = $$('option', sectionSelect).some(function (opt) {
            return opt.value === s.section;
        });
        if (!known && s.section) {
            var opt = document.createElement('option');
            opt.value = s.section;
            opt.textContent = s.section + ' (not in sections list)';
            sectionSelect.appendChild(opt);
        }
        sectionSelect.value = s.section || '';

        var radio = $('input[name="es-condition"][value="' + (s.group_type || '') + '"]');
        if (radio) {
            radio.checked = true;
        }

        var tutorSelect = $('#es-tutor');
        fillTutorSelect(tutorSelect);
        if (
            s.selected_character &&
            !Admin.TUTORS.some(function (t) {
                return t.key === s.selected_character;
            })
        ) {
            var odd = document.createElement('option');
            odd.value = s.selected_character;
            odd.textContent = s.selected_character + ' (not in the tutor list)';
            tutorSelect.appendChild(odd);
        }
        tutorSelect.value = s.selected_character || '';
        tutorSelect.setAttribute('data-initial', s.selected_character || '');
        syncTutorField('es');

        Admin.openModal('modal-edit-student');
    }
    Admin.openEditStudent = openEditStudent;

    function fillScoreField(id, value) {
        var input = $('#' + id);
        input.value = value == null ? '' : value;
        input.setAttribute('data-initial', input.value);
    }

    function paintScorePreview(test) {
        var out = $('#es-' + test + '-result');
        var raw = $('#es-' + test + '-raw').value;
        var max = $('#es-' + test + '-max').value;
        var pair = Admin.readScorePair(raw, max);
        var legacy = out.getAttribute('data-legacy');

        out.classList.toggle('is-error', !pair.ok);
        if (!pair.ok) {
            out.textContent = pair.error;
        } else if (pair.score == null) {
            out.textContent = legacy ? 'Legacy score: ' + legacy : '';
        } else {
            out.innerHTML =
                'Transmuted: <strong class="tnum">' +
                Admin.esc(Admin.formatScore(pair.score)) +
                '</strong>';
        }
        markScoreInvalid(test, false);
    }
    Admin.paintScorePreview = paintScorePreview;

    function markScoreInvalid(test, invalid) {
        $('#es-' + test + '-raw').classList.toggle('is-invalid', invalid);
        $('#es-' + test + '-max').classList.toggle('is-invalid', invalid);
    }

    function fillConsentBox(id, value) {
        var box = $('#' + id);
        box.checked = value === true;
        box.setAttribute('data-initial', box.checked ? 'true' : 'false');
        $('#' + id + '-note').textContent = value == null ? 'Not recorded' : '';
    }

    function consentChange(id) {
        var box = $('#' + id);
        var now = box.checked ? 'true' : 'false';
        return now === box.getAttribute('data-initial') ? undefined : box.checked;
    }

    async function handleUpdateStudent(event) {
        event.preventDefault();
        Admin.clearFormErrors('edit-student-form');

        var originalEmail = $('#es-original-email').value;
        var first = $('#es-first').value.trim();
        var middle = $('#es-middle').value.trim();
        var last = $('#es-last').value.trim();
        var section = $('#es-section').value;
        var groupType = ($('input[name="es-condition"]:checked') || {}).value;
        var pairs = {};

        var valid = true;
        valid = Admin.setFieldError('es-first', first ? '' : 'First name is required.') && valid;
        valid = Admin.setFieldError('es-last', last ? '' : 'Last name is required.') && valid;
        ['pre', 'post'].forEach(function (test) {
            pairs[test] = Admin.readScorePair(
                $('#es-' + test + '-raw').value,
                $('#es-' + test + '-max').value
            );
            if (!pairs[test].ok) {
                paintScorePreview(test);
                markScoreInvalid(test, true);
                if (valid) {
                    $('#es-' + test + '-raw').focus();
                }
                valid = false;
            }
        });
        if (!valid) {
            return;
        }

        var fullName = [first, middle, last].filter(Boolean).join(' ');
        var release = Admin.setBusy($('#es-submit'), 'Saving…');

        try {
            var payload = {
                full_name: fullName,
                section: section
            };
            payload.group_type = groupType;

            ['pre', 'post'].forEach(function (test) {
                var rawInput = $('#es-' + test + '-raw');
                var maxInput = $('#es-' + test + '-max');
                if (
                    Admin.sameNumber(pairs[test].raw, rawInput.getAttribute('data-initial')) &&
                    Admin.sameNumber(pairs[test].max, maxInput.getAttribute('data-initial'))
                ) {
                    return;
                }
                payload[test + '_test_raw_score'] = pairs[test].raw;
                payload[test + '_test_max_score'] = pairs[test].max;
            });
            var consent = consentChange('es-consent');
            var assent = consentChange('es-assent');
            if (consent !== undefined) {
                payload.parental_consent = consent;
            }
            if (assent !== undefined) {
                payload.student_assent = assent;
            }

            var updateRes = await sb.from('profiles').update(payload).eq('email', originalEmail);

            if (updateRes.error) {
                var updateMsg = Admin.isMissingColumn(updateRes.error)
                    ? Admin.MIGRATION_MISSING
                    : Admin.friendlyDbError(updateRes.error, 'Could not update the profile.');
                Admin.toastErr('Update failed', updateMsg);
                return;
            }

            Admin.closeModal('modal-edit-student');
            Admin.toastOk('Participant updated', fullName + ' was saved.');
            Admin.refreshAll();
        } finally {
            release();
        }
    }
    Admin.handleUpdateStudent = handleUpdateStudent;
})();
