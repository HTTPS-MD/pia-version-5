/*
 * Student forms.
 * Edit a student's name and section in two steps (adding students is in add-students.js).
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

    // the old tutor fields are gone; start-up still calls this
    Admin.initTutorFields = function () {};

    var STEPS = ['Name', 'Section'];
    var stage = 0;
    var snapshot = '';

    function look() {
        return JSON.stringify([
            $('#es-first').value.trim(),
            $('#es-middle').value.trim(),
            $('#es-last').value.trim(),
            $('#es-section').value
        ]);
    }

    function paint() {
        var last = stage === STEPS.length - 1;
        $('#es-step-name').hidden = stage !== 0;
        $('#es-step-section').hidden = stage !== 1;
        $('#es-back').hidden = stage === 0;
        $('#es-next').hidden = last;
        $('#es-submit').hidden = !last;
        $('#es-wiz').innerHTML = STEPS.map(function (label, i) {
            return (
                '<li class="' +
                (i === stage ? 'is-current' : i < stage ? 'is-done' : '') +
                '" data-es-go="' +
                i +
                '" role="button" tabindex="0"' +
                (i === stage ? ' aria-current="step"' : '') +
                '><span>' +
                (i + 1) +
                '</span> ' +
                label +
                '</li>'
            );
        }).join('');
    }

    function check() {
        Admin.clearFormErrors('edit-student-form');
        if (stage !== 0) {
            return true;
        }
        var first = $('#es-first').value.trim();
        var last = $('#es-last').value.trim();
        var okFirst = Admin.setFieldError('es-first', first ? '' : 'First name is required.');
        var okLast = Admin.setFieldError('es-last', last ? '' : 'Last name is required.');
        if (!okFirst) {
            $('#es-first').focus();
        } else if (!okLast) {
            $('#es-last').focus();
        }
        return okFirst && okLast;
    }

    function go(to) {
        if (to > stage && !check()) {
            return;
        }
        stage = Math.max(0, Math.min(STEPS.length - 1, to));
        paint();
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

        stage = 0;
        paint();
        snapshot = look();
        Admin.openModal('modal-edit-student');
    }
    Admin.openEditStudent = openEditStudent;

    async function handleUpdateStudent(event) {
        event.preventDefault();
        if (stage < STEPS.length - 1) {
            go(stage + 1);
            return;
        }
        Admin.clearFormErrors('edit-student-form');

        var originalEmail = $('#es-original-email').value;
        var first = $('#es-first').value.trim();
        var middle = $('#es-middle').value.trim();
        var last = $('#es-last').value.trim();
        var section = $('#es-section').value;

        if (!first || !last) {
            go(0);
            check();
            return;
        }

        var fullName = [first, middle, last].filter(Boolean).join(' ');
        var release = Admin.setBusy($('#es-submit'), 'Saving…');

        try {
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
        $('#es-next').addEventListener('click', function () {
            go(stage + 1);
        });
        $('#es-back').addEventListener('click', function () {
            go(stage - 1);
        });
        $('#es-wiz').addEventListener('click', function (event) {
            var li = event.target.closest('[data-es-go]');
            if (li) {
                go(Number(li.getAttribute('data-es-go')));
            }
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
