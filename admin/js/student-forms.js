(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function tutorName(key) {
        var t = Admin.TUTORS.filter(function (x) {
            return x.key === key;
        })[0];
        return t ? t.name : key || '';
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

    var snapshot = '';

    function look() {
        return JSON.stringify([
            $('#es-first').value.trim(),
            $('#es-middle').value.trim(),
            $('#es-last').value.trim(),
            $('#es-number').value.replace(/\D/g, ''),
            $('#es-section').value
        ]);
    }

    function syncSave() {
        var save = $('#es-submit');
        if (save) {
            save.disabled = look() === snapshot;
        }
    }

    function openEditStudent(email) {
        var s = Admin.findStudent(email);
        if (!s) {
            return;
        }

        Admin.clearFormErrors('edit-student-form');

        var parts = (s.full_name || '').trim().split(/\s+/).filter(Boolean);
        var first = parts[0] || '',
            middle = '',
            last = '';
        if (parts.length === 2) {
            last = parts[1];
        } else if (parts.length === 3) {
            middle = parts[1];
            last = parts[2];
        } else if (parts.length > 3) {
            last = parts[parts.length - 1];
            middle = parts[parts.length - 2];
            first = parts.slice(0, -2).join(' ');
        }

        $('#es-original-email').value = s.email;
        $('#es-first').value = first;
        $('#es-middle').value = middle;
        $('#es-last').value = last;

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
        if (Admin.refreshCustomSelect) {
            Admin.refreshCustomSelect('es-section');
        }

        $('#es-number').value = '';
        $('#es-number').disabled = true;
        var base = {
            first: $('#es-first').value,
            middle: $('#es-middle').value,
            last: $('#es-last').value,
            number: '',
            section: $('#es-section').value
        };
        function snapOf() {
            return JSON.stringify([
                base.first.trim(),
                base.middle.trim(),
                base.last.trim(),
                base.number.replace(/\D/g, ''),
                base.section
            ]);
        }
        var draft = Admin.drafts['student:' + s.email] || null;
        function applyDraft() {
            if (!draft) {
                return;
            }
            $('#es-first').value = draft.first;
            $('#es-middle').value = draft.middle;
            $('#es-last').value = draft.last;
            $('#es-number').value = draft.number;
            $('#es-section').value = draft.section;
            if (Admin.refreshCustomSelect) {
                Admin.refreshCustomSelect('es-section');
            }
        }
        snapshot = snapOf();
        applyDraft();
        syncSave();
        Admin.openModal('modal-edit-student');
        if (draft) {
            Admin.toastOk('Draft restored', 'Your unsaved changes are back.');
        }

        sb.from('profiles')
            .select('first_name, middle_name, last_name')
            .eq('email', s.email)
            .maybeSingle()
            .then(function (res) {
                var d = res && res.data;
                if (!d || (!d.first_name && !d.middle_name && !d.last_name)) {
                    return;
                }
                if ($('#es-original-email').value !== s.email) {
                    return;
                }
                base.first = d.first_name || '';
                base.middle = d.middle_name || '';
                base.last = d.last_name || '';
                if (!draft) {
                    $('#es-first').value = base.first;
                    $('#es-middle').value = base.middle;
                    $('#es-last').value = base.last;
                }
                snapshot = snapOf();
                syncSave();
            });
        window.PIACheckin.numberFor(s.email).then(
            function (number) {
                var field = $('#es-number');
                base.number = number;
                if (!draft) {
                    field.value = number;
                }
                field.disabled = false;
                field.setAttribute('data-initial', number);
                snapshot = snapOf();
                syncSave();
            },
            function () {
                $('#es-number').disabled = false;
                $('#es-number').setAttribute('data-initial', '');
                syncSave();
            }
        );
    }
    Admin.openEditStudent = openEditStudent;

    async function handleUpdateStudent(event) {
        event.preventDefault();
        Admin.clearFormErrors('edit-student-form');

        var originalEmail = $('#es-original-email').value;
        var first = $('#es-first').value.trim();
        var middle = $('#es-middle').value.trim();
        var last = $('#es-last').value.trim();
        var section = $('#es-section').value;
        var number = $('#es-number').value.replace(/\D/g, '');
        var numberBefore = $('#es-number').getAttribute('data-initial') || '';

        var valid = true;
        valid = Admin.setFieldError('es-first', first ? '' : 'First name is required.') && valid;
        valid = Admin.setFieldError('es-last', last ? '' : 'Last name is required.') && valid;
        valid =
            Admin.setFieldError(
                'es-number',
                number.length === 11 ? '' : 'Student number must be 11 digits.'
            ) && valid;
        valid = Admin.setFieldError('es-section', section ? '' : 'Choose a section.') && valid;
        if (!valid) {
            return;
        }

        var current = (Admin.state.cohort || []).filter(function (c) {
            return String(c.email || '').toLowerCase() === originalEmail.toLowerCase();
        })[0];
        if (current && current.section !== section) {
            var inside = Admin.GATES.filter(function (g) {
                return g.label === current.current_stage;
            })[0];
            if (inside || Admin.isOnline(current)) {
                Admin.setFieldError(
                    'es-section',
                    inside
                        ? 'This student is in ' + inside.title + ' now. Close it for the old section first.'
                        : 'This student is signed in now. Sign them out first, then move them.'
                );
                return;
            }
        }

        var fullName = [first, middle, last].filter(Boolean).join(' ');
        var release = Admin.setBusy($('#es-submit'), 'Saving…');

        try {
            if (number && number !== numberBefore) {
                var saved = await window.PIACheckin.saveNumberFor(originalEmail, number);
                if (!saved.ok) {
                    Admin.setFieldError('es-number', saved.message || 'Could not save the student number.');
                    return;
                }
            }

            var updateRes = await sb
                .from('profiles')
                .update({
                    full_name: fullName,
                    section: section,
                    first_name: first,
                    middle_name: middle || null,
                    last_name: last
                })
                .eq('email', originalEmail);
            if (updateRes.error && Admin.isMissingColumn(updateRes.error)) {
                updateRes = await sb
                    .from('profiles')
                    .update({ full_name: fullName, section: section })
                    .eq('email', originalEmail);
            }

            if (updateRes.error) {
                Admin.toastErr(
                    'Update failed',
                    Admin.friendlyDbError(updateRes.error, 'Could not update the profile.')
                );
                return;
            }

            delete Admin.drafts['student:' + originalEmail];
            snapshot = look();
            Admin.closeModal('modal-edit-student');
            Admin.toastOk('Participant updated', fullName + ' was saved.');
            Admin.refreshAll();
        } finally {
            release();
        }
    }
    Admin.handleUpdateStudent = handleUpdateStudent;

    function initEditWizard() {
        var overlay = $('#modal-edit-student');
        ['input', 'change', 'click'].forEach(function (type) {
            overlay.addEventListener(type, function () {
                setTimeout(syncSave, 0);
            });
        });
        function guard(event) {
            if (look() === snapshot) {
                return;
            }
            event.stopImmediatePropagation();
            event.preventDefault();
            var email = $('#es-original-email').value;
            Admin.askUnsaved().then(function (answer) {
                if (!answer) {
                    return;
                }
                if (answer === 'save') {
                    Admin.drafts['student:' + email] = {
                        first: $('#es-first').value,
                        middle: $('#es-middle').value,
                        last: $('#es-last').value,
                        number: $('#es-number').value,
                        section: $('#es-section').value
                    };
                } else {
                    delete Admin.drafts['student:' + email];
                }
                snapshot = look();
                Admin.closeModal('modal-edit-student');
            });
        }
        overlay.addEventListener(
            'click',
            function (event) {
                if (event.target.closest('[data-modal-close]')) {
                    guard(event);
                }
            },
            true
        );
        overlay.addEventListener(
            'mousedown',
            function (event) {
                if (event.target === overlay) {
                    guard(event);
                }
            },
            true
        );
        document.addEventListener(
            'keydown',
            function (event) {
                var layers = Admin.openLayers;
                if (event.key === 'Escape' && layers[layers.length - 1] === overlay) {
                    guard(event);
                }
            },
            true
        );
    }
    initEditWizard();
})();
