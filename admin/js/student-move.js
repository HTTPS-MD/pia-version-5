/*
 * Deleting a section.
 * A section with students is deleted by saying which section they move to.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;
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
        if (options.teacher) {
            bits.push(options.teacher + ' will be unassigned.');
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
        wireDelete();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
