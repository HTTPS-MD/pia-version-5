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

    var pending = null;

    var NEW = '__new__';

    function newNameProblem() {
        var name = $('#ds-new').value.trim();
        if (!name) {
            return 'Type a name for the new section.';
        }
        var taken = (Admin.state.sections || []).some(function (s) {
            return String(s.name).toLowerCase() === name.toLowerCase();
        });
        return taken ? 'A section with that name already exists.' : '';
    }

    function paintDelete() {
        var p = pending;
        var move = $('#ds-move').value;
        var typed = $('#ds-type').value.trim();
        var making = move === NEW;
        $('#ds-new-field').hidden = !p.students || !making;
        var okMove = !p.students || (!!move && (!making || !newNameProblem()));
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
        $('#ds-error').textContent = '';
        $('#ds-new').value = '';
        fill($('#ds-move'), others, 'Choose a section');
        var pick = $('#ds-move');
        pick.insertAdjacentHTML('beforeend', '<option value="' + NEW + '">+ New section</option>');
        if (Admin.refreshCustomSelect) {
            Admin.refreshCustomSelect('ds-move');
        }
        paintDelete();
        Admin.openModal('modal-delete-section');
    }
    Admin.openDeleteSection = openDeleteSection;

    function wireDelete() {
        $('#ds-move').addEventListener('change', function () {
            $('#ds-error').textContent = '';
            paintDelete();
            if ($('#ds-move').value === NEW) {
                $('#ds-new').focus();
            }
        });
        $('#ds-new').addEventListener('input', paintDelete);
        $('#ds-type').addEventListener('input', paintDelete);
        $('#ds-confirm').addEventListener('click', async function () {
            if (!pending || pending.running) {
                return;
            }
            pending.running = true;
            var release = Admin.setBusy($('#ds-confirm'), 'Deleting…');
            try {
                var target = $('#ds-move').value;
                if (pending.students && target === NEW) {
                    var problem = newNameProblem();
                    if (problem) {
                        throw { message: problem };
                    }
                    target = $('#ds-new').value.trim();
                    var made = await sb.from('sections').insert([{ name: target }]);
                    if (made.error) {
                        throw made.error;
                    }
                }
                await pending.run(target);
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
