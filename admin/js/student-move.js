/*
 * Moving students and deleting a section.
 * Tick students in the table and move them to another section, and delete a section by saying where its students go.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;
    var picked = {};
    var busy = false;

    function names(except) {
        return (Admin.state.sections || [])
            .map(function (s) {
                return s.name;
            })
            .filter(function (n) {
                return n !== except;
            });
    }

    function fill(select, list, placeholder) {
        select.innerHTML =
            '<option value="">' +
            Admin.esc(placeholder) +
            '</option>' +
            list
                .map(function (n) {
                    return '<option value="' + Admin.esc(n) + '">' + Admin.esc(n) + '</option>';
                })
                .join('');
        if (select.id && Admin.refreshCustomSelect) {
            Admin.refreshCustomSelect(select.id);
        }
    }

    function count() {
        return Object.keys(picked).length;
    }

    function paintPicks() {
        var boxes = $$('#student-tbody input[data-pick]');
        boxes.forEach(function (box) {
            box.checked = !!picked[box.getAttribute('data-pick')];
        });
        var all = $('#pick-all');
        if (all) {
            all.checked = boxes.length > 0 && boxes.every(function (b) {
                return b.checked;
            });
        }
        var bar = $('#pick-bar');
        var n = count();
        bar.hidden = n === 0;
        $('#pick-count').textContent = n + ' selected';
        var select = $('#pick-section');
        if (n && !select.getAttribute('data-filled')) {
            fill(select, names(''), 'Move to…');
            select.setAttribute('data-filled', '1');
        }
        $('#pick-move').disabled = !n || !select.value;
    }
    Admin.paintPicks = paintPicks;

    async function movePicked() {
        var target = $('#pick-section').value;
        var emails = Object.keys(picked);
        if (!target || !emails.length || busy) {
            return;
        }
        var ok = await Admin.confirmAction({
            heading: 'Move ' + emails.length + (emails.length === 1 ? ' student' : ' students') + ' to ' + target + '?',
            message: 'Their stage, condition, answers and scores do not change. If a stage is open for ' + target + ', they can enter it.',
            confirmLabel: 'Move',
            tone: 'accent'
        });
        if (!ok) {
            return;
        }
        busy = true;
        var release = Admin.setBusy($('#pick-move'), 'Moving…');
        var res = await sb.rpc('admin_move_students', { p_emails: emails, p_section: target });
        release();
        busy = false;
        if (res.error) {
            Admin.toastErr('Students not moved', Admin.friendlyDbError(res.error, 'The move was rejected.'));
            return;
        }
        picked = {};
        $('#pick-section').removeAttribute('data-filled');
        Admin.toastOk('Students moved', emails.length + ' now in ' + target + '.');
        paintPicks();
        Admin.refreshAll();
    }

    function wirePicks() {
        $('#student-tbody').addEventListener('change', function (event) {
            var box = event.target.closest('[data-pick]');
            if (!box) {
                return;
            }
            var email = box.getAttribute('data-pick');
            if (box.checked) {
                picked[email] = true;
            } else {
                delete picked[email];
            }
            paintPicks();
        });
        $('#pick-all').addEventListener('change', function (event) {
            $$('#student-tbody input[data-pick]').forEach(function (box) {
                var email = box.getAttribute('data-pick');
                if (event.target.checked) {
                    picked[email] = true;
                } else {
                    delete picked[email];
                }
            });
            paintPicks();
        });
        $('#pick-section').addEventListener('change', paintPicks);
        $('#pick-clear').addEventListener('click', function () {
            picked = {};
            paintPicks();
        });
        $('#pick-move').addEventListener('click', movePicked);
    }

    // ---- delete a section ----
    var pending = null;

    function paintDelete() {
        var p = pending;
        var move = $('#ds-move').value;
        var typed = $('#ds-type').value.trim();
        var okMove = !p.students || !!move;
        var okType = !p.students || typed === p.name;
        $('#ds-confirm').disabled = !okMove || !okType || p.running;
    }

    function openDeleteSection(options) {
        pending = options;
        pending.running = false;
        var others = names(options.name);
        var bits = [];
        if (options.students) {
            bits.push(
                options.students +
                    (options.students === 1 ? ' student is' : ' students are') +
                    ' in this section.'
            );
        }
        if (options.professor) {
            bits.push(options.professor + ' will be unassigned.');
        }
        bits.push('This cannot be undone.');
        $('#ds-title').textContent = 'Delete ' + options.name + '?';
        $('#ds-text').textContent = bits.join(' ');
        $('#ds-move-field').hidden = !options.students;
        $('#ds-type-field').hidden = !options.students;
        $('#ds-type-label').textContent = 'Type ' + options.name + ' to confirm';
        $('#ds-type').value = '';
        $('#ds-error').textContent =
            options.students && !others.length
                ? 'Create another section first, so the students have somewhere to go.'
                : '';
        fill($('#ds-move'), others, 'Choose a section');
        paintDelete();
        Admin.openModal('modal-delete-section');
    }
    Admin.openDeleteSection = openDeleteSection;

    function wireDelete() {
        $('#ds-move').addEventListener('change', paintDelete);
        $('#ds-type').addEventListener('input', paintDelete);
        $('#ds-confirm').addEventListener('click', async function () {
            if (!pending || pending.running) {
                return;
            }
            pending.running = true;
            var release = Admin.setBusy($('#ds-confirm'), 'Deleting…');
            try {
                await pending.run($('#ds-move').value);
                release();
                Admin.closeModal('modal-delete-section');
                await pending.done();
            } catch (error) {
                release();
                pending.running = false;
                $('#ds-error').textContent = Admin.friendlyDbError(error, 'The section was not deleted.');
                paintDelete();
                if (pending.failed) {
                    pending.failed(error);
                }
            }
        });
    }

    function init() {
        wirePicks();
        wireDelete();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
