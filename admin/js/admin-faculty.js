/*
 * Professors.
 * The professor list, profile, devices, and adding or removing a professor.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function facultyProgress(f) {
        var dash = '<td class="col-right muted">—</td>';
        if (!f.assigned_section || !Admin.state.cohortLoaded) {
            return dash;
        }
        if (
            !Admin.state.sections.some(function (sec) {
                return sec.name === f.assigned_section;
            })
        ) {
            return dash;
        }
        var members = Admin.state.cohort.filter(function (s) {
            return s.section === f.assigned_section;
        });
        return '<td class="col-right mono">' + members.length + '</td>';
    }

    function facultyOcean(f) {
        var info = (Admin.state.facultyOcean || {})[String(f.email || '').toLowerCase()];
        if (!info) {
            return '<td class="muted">—</td>';
        }
        if (info.done && info.row) {
            var r = info.row;
            return (
                '<td class="mono" title="Raw scores, 0 to 40. A low N means more stress.">' +
                'E ' +
                r.ocean_e +
                ' · A ' +
                r.ocean_a +
                ' · C ' +
                r.ocean_c +
                ' · N ' +
                r.ocean_n +
                ' · O ' +
                r.ocean_o +
                '</td>'
            );
        }
        return (
            '<td><span class="badge">' + (info.row ? 'Retake pending' : 'Not yet') + '</span></td>'
        );
    }

    function renderFaculty(term) {
        var needle = Admin.sanitizeFilterTerm(term).toLowerCase();
        var rows = Admin.state.faculty.filter(function (f) {
            if (!needle) {
                return true;
            }
            return (
                ((f.name || '') + ' ' + (f.email || '') + ' ' + (f.department || ''))
                    .toLowerCase()
                    .indexOf(needle) !== -1
            );
        });

        $('#faculty-empty').classList.toggle('is-hidden', rows.length !== 0);

        $('#faculty-tbody').innerHTML = rows
            .map(function (f) {
                var active = (f.status || '') === 'active';
                return (
                    '' +
                    '<tr class="is-clickable" tabindex="0" data-faculty="' +
                    Admin.esc(f.email) +
                    '"' +
                    ' aria-label="Open profile: ' +
                    Admin.esc(f.name || f.email) +
                    '">' +
                    '<td>' +
                    Admin.userCell({ full_name: f.name, email: f.email }) +
                    '</td>' +
                    '<td>' +
                    (f.assigned_section
                        ? '<button type="button" class="cell-link" data-section-open="' +
                          Admin.esc(f.assigned_section) +
                          '"' +
                          ' aria-label="Show students in section ' +
                          Admin.esc(f.assigned_section) +
                          '">' +
                          Admin.esc(f.assigned_section) +
                          '</button>'
                        : '<span class="badge">Unassigned</span>') +
                    '</td>' +
                    facultyProgress(f) +
                    facultyOcean(f) +
                    '<td><span class="badge ' +
                    (active ? 'badge-accent' : '') +
                    '">' +
                    (active ? 'Active' : 'Inactive') +
                    '</span></td>' +
                    '</tr>'
                );
            })
            .join('');
    }
    Admin.renderFaculty = renderFaculty;

    function initFaculty() {
        $('#faculty-search').addEventListener(
            'input',
            Admin.debounce(function (event) {
                renderFaculty(event.target.value);
            }, 200)
        );

        $('#faculty-tbody').addEventListener('click', function (event) {
            var section = event.target.closest('[data-section-open]');
            if (section) {
                Admin.showSection(section.getAttribute('data-section-open'));
                return;
            }
            var row = event.target.closest('[data-faculty]');
            if (row) {
                openFacultyProfile(row.getAttribute('data-faculty'), row);
            }
        });

        $('#faculty-tbody').addEventListener('keydown', function (event) {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            var row = event.target.closest('[data-faculty]');
            if (!row || event.target !== row) {
                return;
            }
            event.preventDefault();
            openFacultyProfile(row.getAttribute('data-faculty'), row);
        });

        $('#faculty-change').addEventListener('click', function () {
            if (window.PIACheckin && window.PIACheckin.changeProfessor) {
                window.PIACheckin.changeProfessor();
            }
        });

        $('#faculty-reset').addEventListener('click', function () {
            if (Admin.state.activeFaculty) {
                resetFacultyPassword(Admin.state.activeFaculty.email, this);
            }
        });

        $('#faculty-signout').addEventListener('click', function () {
            if (Admin.state.activeFaculty) {
                signOutFacultyEverywhere(Admin.state.activeFaculty.email, this);
            }
        });

        $('#faculty-delete').addEventListener('click', function () {
            if (Admin.state.activeFaculty) {
                Admin.closeModal('modal-faculty');
                deleteFaculty(Admin.state.activeFaculty.email);
            }
        });
    }
    Admin.initFaculty = initFaculty;

    function setFacultyStatus(text, tone) {
        var node = $('#faculty-status-msg');
        node.textContent = text;
        node.className = 'form-status' + (tone ? ' is-' + tone : '');
    }

    async function resetFacultyPassword(email, sourceBtn) {
        var ok = await Admin.confirmAction({
            title: 'Reset password',
            heading: 'Send a reset link to ' + email + '?',
            message:
                'They will choose their own new password through the emailed link. ' +
                'No password is set or revealed here.',
            confirmLabel: 'Send reset email',
            tone: 'accent'
        });
        if (!ok) {
            return;
        }

        var release = Admin.setBusy(sourceBtn, 'Sending…');
        setFacultyStatus('Sending the reset email…', '');
        var res;
        try {
            res = await sb.auth.resetPasswordForEmail(email, {
                redirectTo: Admin.activationRedirect()
            });
        } catch (err) {
            res = { error: { message: (err && err.message) || 'The request did not complete.' } };
        }
        release();

        if (!Admin.state.activeFaculty || Admin.state.activeFaculty.email !== email) {
            return;
        }
        if (res.error) {
            setFacultyStatus(
                'The reset email was not sent: ' + Admin.authFailureText(res.error, ''),
                'error'
            );
            return;
        }
        setFacultyStatus(
            'The service accepted the request. ' +
                email +
                ' can use the link in the email to choose a new password.',
            'ok'
        );
    }

    function openFacultyProfile(email, trigger) {
        var f = Admin.state.faculty.filter(function (row) {
            return row.email === email;
        })[0];
        if (!f) {
            return;
        }

        Admin.state.activeFaculty = f;
        $('#faculty-title').textContent = f.name || 'Faculty profile';
        var sectionActions = $('#faculty-section-actions');
        if (sectionActions) {
            var current = window.PIASectionNow && f.assigned_section === window.PIASectionNow;
            sectionActions.style.display = current ? '' : 'none';
            $('#faculty-section-label').textContent = 'Section ' + (f.assigned_section || '');
        }
        $('#faculty-initials').textContent = Admin.initialsOf(f.name, f.email);
        $('#faculty-subject').textContent = f.email;
        $('#faculty-dept').textContent = f.department || '—';
        $('#faculty-section').textContent = f.assigned_section || 'Unassigned';
        $('#faculty-status').textContent = (f.status || '') === 'active' ? 'Active' : 'Inactive';
        $('#faculty-devices').textContent = '…';
        setFacultyStatus('', '');

        Admin.openModal('modal-faculty', trigger);
        loadFacultyDevices(f.email);
    }

    async function loadFacultyDevices(email) {
        var res = await sb
            .from('profiles')
            .select('active_devices, max_devices')
            .eq('email', email)
            .maybeSingle();
        if (!Admin.state.activeFaculty || Admin.state.activeFaculty.email !== email) {
            return;
        }
        $('#faculty-devices').textContent =
            res.error || !res.data
                ? '—'
                : (res.data.active_devices || []).length +
                  ' of ' +
                  Admin.toInt(res.data.max_devices, 1) +
                  ' in use';
    }

    async function signOutFacultyEverywhere(email, sourceBtn) {
        var ok = await Admin.confirmAction({
            title: 'Sign out everywhere',
            heading: 'Sign ' + email + ' out everywhere?',
            message:
                'Every session for this account ends immediately and each of their devices is ' +
                'freed. They sign in again with their password.',
            confirmLabel: 'Sign out everywhere'
        });
        if (!ok) {
            return;
        }

        var release = Admin.setBusy(sourceBtn, 'Signing out…');
        var res = await sb.rpc('admin_revoke_sessions', { p_email: email });
        release();

        if (res.error) {
            Admin.toastErr(
                'Sign-out failed',
                Admin.friendlyDbError(res.error, 'Their sessions were not ended.')
            );
            return;
        }

        Admin.toastOk('Signed out everywhere', email + ' was signed out of every device.');
        if (Admin.state.activeFaculty && Admin.state.activeFaculty.email === email) {
            loadFacultyDevices(email);
        }
    }

    async function handleRegisterProfessor(event) {
        event.preventDefault();
        Admin.clearFormErrors('add-professor-form');

        var name = $('#ap-name').value.trim();
        var email = Admin.normalizeEmail($('#ap-email').value);
        var department = $('#ap-dept').value.trim();
        var assignedSection = $('#ap-section').value;

        var valid = true;
        valid = Admin.setFieldError('ap-name', name ? '' : 'Full name is required.') && valid;
        valid =
            Admin.setFieldError(
                'ap-email',
                Admin.isEmail(email) ? '' : 'Enter a valid email address.'
            ) && valid;
        valid =
            Admin.setFieldError('ap-dept', department ? '' : 'Department is required.') && valid;
        if (!valid) {
            return;
        }

        var release = Admin.setBusy($('#ap-submit'), 'Registering…');

        try {
            var existing = await sb
                .from('profiles')
                .select('email')
                .eq('email', email)
                .maybeSingle();

            if (existing.data) {
                Admin.setFieldError('ap-email', 'This email already belongs to another account.');
                Admin.toastErr('Duplicate email', email + ' is already in use.');
                return;
            }

            var authRes = await sb.rpc('admin_create_auth_user', {
                target_email: email,
                default_password: Admin.generateSecurePassword()
            });

            if (authRes.error) {
                Admin.toastErr(
                    'Auth user not created',
                    Admin.friendlyDbError(authRes.error, 'Could not create the auth user.')
                );
                return;
            }

            var regRes = await sb.rpc('admin_register_teacher', {
                p_email: email,
                p_name: name,
                p_department: department,
                p_assigned_section: assignedSection
            });

            if (regRes.error) {
                Admin.showNotice(
                    'Registration incomplete',
                    Admin.friendlyDbError(regRes.error, 'Could not save the teacher.') +
                        '\n\nAn auth user was already created for ' +
                        email +
                        '. It must be deleted before registering this professor again.',
                    'danger'
                );
                return;
            }

            Admin.closeModal('modal-add-professor');
            $('#add-professor-form').reset();
            Admin.clearFormErrors('add-professor-form');

            Admin.toastOk('Professor added', name + ' now has observer access.');
            await Admin.loadFaculty();
            Admin.renderSections();
        } finally {
            release();
        }
    }
    Admin.handleRegisterProfessor = handleRegisterProfessor;

    async function deleteFaculty(email) {
        var ok = await Admin.confirmAction({
            title: 'Remove faculty',
            heading: 'Permanently delete ' + email + '?',
            message:
                'The auth user, the faculty record and the linked profile are all removed. ' +
                'Student data is not affected.',
            confirmLabel: 'Remove faculty'
        });
        if (!ok) {
            return;
        }

        var res = await sb.rpc('admin_delete_user', { target_email: email });

        if (res.error) {
            Admin.toastErr(
                'Removal failed',
                Admin.friendlyDbError(res.error, 'The account was not deleted.')
            );
            return;
        }

        Admin.toastOk('Faculty removed', email + ' no longer has access.');
        await Admin.loadFaculty();
        Admin.renderSections();
    }
})();
