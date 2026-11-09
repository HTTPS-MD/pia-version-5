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

        $('#faculty-remove').addEventListener('click', async function () {
            var f = Admin.state.activeFaculty;
            if (!f) {
                return;
            }
            var holds = !!(
                window.PIACheckin &&
                window.PIACheckin.holdsSection &&
                window.PIACheckin.holdsSection(f.email)
            );
            if (!holds) {
                if (await deleteFaculty(f.email)) {
                    Admin.closeModal('modal-faculty');
                }
                return;
            }
            for (;;) {
                var answer = await Admin.confirmAction({
                    heading: 'Remove ' + Admin.whoIs(f.email) + '?',
                    message: 'Removing from the section keeps their account.',
                    confirmLabel: 'Remove from section',
                    altLabel: 'Delete',
                    altTone: 'danger',
                    tone: 'accent',
                    noCancel: true
                });
                if (answer === true) {
                    window.PIACheckin.removeFromSection({ confirmed: true });
                    break;
                }
                if (answer === 'alt') {
                    if (await deleteFaculty(f.email)) {
                        Admin.closeModal('modal-faculty');
                        break;
                    }
                    continue;
                }
                break;
            }
        });

        $('#faculty-edit').addEventListener('click', openEditTeacher);
        $('#edit-teacher-form').addEventListener('submit', saveTeacher);
        ['input', 'change'].forEach(function (type) {
            $('#edit-teacher-form').addEventListener(type, syncTeacherSave);
        });
        var teacherOverlay = $('#modal-edit-teacher');
        function guardTeacher(event) {
            if (teacherLook() === teacherSnapshot) {
                return;
            }
            event.stopImmediatePropagation();
            event.preventDefault();
            var who = $('#et-original-email').value;
            Admin.askUnsaved().then(function (answer) {
                if (!answer) {
                    return;
                }
                Admin.drafts['teacher:' + who] =
                    answer === 'save' ? { name: $('#et-name').value, email: $('#et-email').value } : null;
                teacherSnapshot = teacherLook();
                Admin.closeModal('modal-edit-teacher');
            });
        }
        teacherOverlay.addEventListener(
            'click',
            function (event) {
                if (event.target.closest('[data-modal-close]')) {
                    guardTeacher(event);
                }
            },
            true
        );
        teacherOverlay.addEventListener(
            'mousedown',
            function (event) {
                if (event.target === teacherOverlay) {
                    guardTeacher(event);
                }
            },
            true
        );

        $('#faculty-signout').addEventListener('click', function () {
            if (Admin.state.activeFaculty) {
                signOutFacultyEverywhere(Admin.state.activeFaculty.email, this);
            }
        });

    }
    Admin.initFaculty = initFaculty;

    function setFacultyStatus(text, tone) {
        var node = $('#faculty-status-msg');
        node.textContent = text;
        node.className = 'form-status' + (tone ? ' is-' + tone : '');
    }


    var OCEAN_TRAITS = [
        { key: 'ocean_e', name: 'Extroversion' },
        { key: 'ocean_a', name: 'Agreeableness' },
        { key: 'ocean_c', name: 'Conscientiousness' },
        { key: 'ocean_n', name: 'Neuroticism' },
        { key: 'ocean_o', name: 'Openness' }
    ];

    function renderFacultyOcean(f) {
        var info = (Admin.state.facultyOcean || {})[String(f.email || '').toLowerCase()];
        var box = $('#faculty-traits');
        var meta = $('#faculty-ocean-meta');
        meta.textContent = '';
        if (!info || !info.row) {
            box.innerHTML = '<p class="muted">Not taken yet.</p>';
            return;
        }
        var r = info.row;
        var top = OCEAN_TRAITS.reduce(function (best, t) {
            var v = r[t.key];
            return v != null && (best === null || v > best) ? v : best;
        }, null);
        var strongest = OCEAN_TRAITS.filter(function (t) {
            return top !== null && r[t.key] === top;
        }).map(function (t) {
            return t.name;
        });
        meta.textContent = strongest.length ? 'Dominant: ' + strongest.join(' & ') : '';
        box.innerHTML = OCEAN_TRAITS.map(function (t) {
            var v = r[t.key];
            var width = v == null ? 0 : Math.max(0, Math.min(100, (v / Admin.OCEAN_MAX) * 100));
            return (
                '<div class="trait"><div class="trait-top"><span class="trait-name">' +
                Admin.esc(t.name) +
                '</span><span class="trait-val tnum">' +
                (v == null
                    ? 'n/a'
                    : Admin.esc(v) + '<span class="trait-of"> / ' + Admin.OCEAN_MAX + '</span>') +
                '</span></div><div class="bar"><div class="bar-fill" style="width:' +
                width +
                '%"></div></div></div>'
            );
        }).join('');
    }

    function openFacultyProfile(email, trigger) {
        var f = Admin.state.faculty.filter(function (row) {
            return row.email === email;
        })[0];
        if (!f) {
            return;
        }

        Admin.state.activeFaculty = f;
        $('#faculty-title').textContent = f.name || 'Teacher profile';
        $('#faculty-initials').textContent = Admin.initialsOf(f.name, f.email);
        $('#faculty-subject').textContent = f.email;
        $('#faculty-dept').textContent = f.department || '—';
        $('#faculty-section').textContent = f.assigned_section || 'Unassigned';
        $('#faculty-status').textContent = (f.status || '') === 'active' ? 'Active' : 'Inactive';
        setFacultyStatus('', '');
        renderFacultyOcean(f);

        Admin.openModal('modal-faculty', trigger);
    }

    function teacherLook() {
        return [$('#et-name').value.trim(), Admin.normalizeEmail($('#et-email').value)].join('|');
    }
    var teacherSnapshot = '';
    function syncTeacherSave() {
        $('#et-submit').disabled = teacherLook() === teacherSnapshot;
        var changed = Admin.normalizeEmail($('#et-email').value) !== Admin.normalizeEmail($('#et-original-email').value);
        $('#et-note').textContent = changed
            ? 'Changing the email signs this teacher out everywhere. They sign in again with the new email and the same password.'
            : '';
    }

    function openEditTeacher() {
        var f = Admin.state.activeFaculty;
        if (!f) {
            return;
        }
        Admin.clearFormErrors('edit-teacher-form');
        $('#et-original-email').value = f.email;
        $('#et-name').value = f.name || '';
        $('#et-email').value = f.email;
        teacherSnapshot = teacherLook();
        var draft = Admin.drafts['teacher:' + f.email];
        if (draft) {
            $('#et-name').value = draft.name;
            $('#et-email').value = draft.email;
        }
        syncTeacherSave();
        Admin.openModal('modal-edit-teacher');
        if (draft) {
            Admin.toastOk('Draft restored', 'Your unsaved changes are back.');
        }
    }

    async function saveTeacher(event) {
        event.preventDefault();
        Admin.clearFormErrors('edit-teacher-form');
        var original = $('#et-original-email').value;
        var name = $('#et-name').value.trim();
        var email = Admin.normalizeEmail($('#et-email').value);
        var section = (Admin.state.activeFaculty && Admin.state.activeFaculty.assigned_section) || '';

        var valid = true;
        valid = Admin.setFieldError('et-name', name ? '' : 'Full name is required.') && valid;
        valid = Admin.setFieldError('et-email', Admin.isEmail(email) ? '' : 'Enter a valid email address.') && valid;
        if (!valid) {
            return;
        }
        var release = Admin.setBusy($('#et-submit'), 'Saving…');
        try {
            var res = await sb.rpc('admin_update_teacher', {
                p_email: original,
                p_name: name,
                p_new_email: email,
                p_section: section
            });
            if (res.error) {
                var msg = Admin.friendlyDbError(res.error, 'Could not update the teacher.');
                if (/email/i.test(msg)) {
                    Admin.setFieldError('et-email', msg);
                } else {
                    Admin.toastErr('Update failed', msg);
                }
                return;
            }
            teacherSnapshot = teacherLook();
            Admin.drafts['teacher:' + original] = null;
            Admin.closeModal('modal-edit-teacher');
            Admin.closeModal('modal-faculty');
            Admin.toastOk('Teacher updated', name + ' was saved.');
            await Admin.loadFaculty();
            Admin.renderSections();
            if (Admin.refreshAll) {
                Admin.refreshAll();
            }
        } finally {
            release();
        }
    }

    async function signOutFacultyEverywhere(email, sourceBtn) {
        var ok = await Admin.confirmAction({
            heading: 'Sign ' + Admin.whoIs(email) + ' out everywhere?',
            message: 'Every session ends now.',
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

        Admin.toastOk('Signed out everywhere', Admin.whoIs(email) + ' was signed out of every device.');
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
                        '. It must be deleted before registering this teacher again.',
                    'danger'
                );
                return;
            }

            Admin.closeModal('modal-add-professor');
            $('#add-professor-form').reset();
            Admin.clearFormErrors('add-professor-form');

            Admin.toastOk('Teacher added', name + ' now has observer access.');
            await Admin.loadFaculty();
            Admin.renderSections();
        } finally {
            release();
        }
    }
    Admin.handleRegisterProfessor = handleRegisterProfessor;

    async function deleteFaculty(email) {
        var ok = await Admin.confirmAction({
            heading: 'Permanently delete ' + Admin.whoIs(email) + '?',
            message: 'Their account and teacher record are removed. Student data stays.',
            confirmLabel: 'Permanently delete'
        });
        if (!ok) {
            return false;
        }

        var res = await sb.rpc('admin_delete_user', { target_email: email });

        if (res.error) {
            Admin.toastErr(
                'Removal failed',
                Admin.friendlyDbError(res.error, 'The account was not deleted.')
            );
            return true;
        }

        var lower = String(email).toLowerCase();
        var rec = await sb.from('professors').delete().ilike('email', lower);
        if (rec.error) {
            Admin.toastErr(
                'Removal incomplete',
                Admin.friendlyDbError(rec.error, 'The teacher record was not deleted.')
            );
            await Admin.loadFaculty();
            return true;
        }
        await sb.from('professor_sections').delete().ilike('email', lower);

        Admin.toastOk('Teacher removed', Admin.whoIs(email) + ' no longer has access.');
        await Admin.loadFaculty();
        Admin.renderSections();
        return true;
    }
})();
