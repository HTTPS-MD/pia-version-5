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
        Admin.openModal('modal-edit-student');
        window.PIACheckin.numberFor(s.email).then(
            function (number) {
                var field = $('#es-number');
                field.value = number;
                field.disabled = false;
                field.setAttribute('data-initial', number);
                snapshot = look();
            },
            function () {
                $('#es-number').disabled = false;
                $('#es-number').setAttribute('data-initial', '');
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
                .update({ full_name: fullName, section: section })
                .eq('email', originalEmail);

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
