/*
 * Student forms.
 * Edit a student (adding students is in add-students.js).
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
        ['es'].forEach(function (prefix) {
            fillTutorSelect($('#' + prefix + '-tutor'));
            $$('input[name="' + prefix + '-condition"]').forEach(function (radio) {
                radio.addEventListener('change', function () {
                    syncTutorField(prefix);
                });
            });
            syncTutorField(prefix);
        });
    }
    Admin.initTutorFields = initTutorFields;

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
