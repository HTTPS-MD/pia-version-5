/*
 * Student forms.
 * Edit a student's name, student number and section (adding students is in add-students.js).
 * The condition is set when the student is created and cannot be changed here.
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

    // Save changes stays off until something in the window has been changed.
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

        // Only the full name is stored, so the parts are worked out from it: the last word is the
        // last name, the word before it the middle name, and the rest the first name
        // ("Mark Daniel Bayona Francisco" is Mark Daniel, Bayona, Francisco).
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
        snapshot = look();
        syncSave();
        Admin.openModal('modal-edit-student');

        // the parts saved with the student win over the guess from the full name
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
                $('#es-first').value = d.first_name || '';
                $('#es-middle').value = d.middle_name || '';
                $('#es-last').value = d.last_name || '';
                snapshot = look();
                syncSave();
            });
        window.PIACheckin.numberFor(s.email).then(
            function (number) {
                var field = $('#es-number');
                field.value = number;
                field.disabled = false;
                field.setAttribute('data-initial', number);
                snapshot = look();
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

        // A student who is signed in or inside a stage is not moved: they would keep playing in a section whose
        // stage may be closed, and their place in the session would stay on the old section.
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
        // closing with edits asks first
        function guard(event) {
            if (look() === snapshot) {
                return;
            }
            event.stopImmediatePropagation();
            event.preventDefault();
            Admin.confirmAction({
                heading: 'Discard changes?',
                message: 'Your edits to this participant are not saved.',
                confirmLabel: 'Discard'
            }).then(function (ok) {
                if (ok) {
                    snapshot = look();
                    Admin.closeModal('modal-edit-student');
                }
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
