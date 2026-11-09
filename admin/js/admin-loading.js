(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function skeletonRows(columns, rows) {
        var out = '';
        for (var r = 0; r < (rows || 5); r++) {
            out += '<tr aria-hidden="true">';
            for (var c = 0; c < columns; c++) {
                out +=
                    '<td>' +
                    (c === 0
                        ? '<div class="cell-user"><span class="skeleton skeleton-avatar"></span>' +
                          '<span class="cell-user-text" style="width:160px">' +
                          '<span class="skeleton skeleton-line" style="width:70%"></span>' +
                          '<span class="skeleton skeleton-line" style="width:90%"></span></span></div>'
                        : '<span class="skeleton skeleton-pill"></span>') +
                    '</td>';
            }
            out += '</tr>';
        }
        return out;
    }
    Admin.skeletonRows = skeletonRows;

    var Loading = (function () {
        var perKey = {};
        var visible = 0;
        var quietNext = false;
        var announceTimer = null;
        var announced = false;

        function paint() {
            $$('[data-region]').forEach(function (el) {
                var busy = el
                    .getAttribute('data-region')
                    .split(/\s+/)
                    .some(function (key) {
                        return perKey[key] > 0;
                    });
                if (busy && el.getAttribute('aria-busy') !== 'true') {
                    el.setAttribute('aria-busy', 'true');
                } else if (!busy && el.hasAttribute('aria-busy')) {
                    el.removeAttribute('aria-busy');
                }
            });

            if (visible > 0) {
                document.body.setAttribute('data-loading', 'true');
            } else {
                document.body.removeAttribute('data-loading');
            }
        }

        function announce() {
            var status = $('#load-status');
            if (!status) {
                return;
            }
            clearTimeout(announceTimer);

            if (visible > 0) {
                announceTimer = setTimeout(function () {
                    status.textContent = 'Loading data…';
                    announced = true;
                }, 600);
            } else if (announced) {
                announced = false;
                status.textContent = 'Data updated.';
                announceTimer = setTimeout(function () {
                    status.textContent = '';
                }, 2500);
            }
        }

        function errorBlock(key, message) {
            return (
                '<div class="state-block region-error">' +
                '<p class="state-title">Couldn’t load this</p>' +
                '<p class="state-desc">' +
                Admin.esc(message) +
                '</p>' +
                '<button class="btn btn-secondary" type="button" data-retry="' +
                Admin.esc(key) +
                '">Try again</button>' +
                '</div>'
            );
        }

        var FAILURE = {
            cohort: [['#sections-tbody', 'rows', 5]],
            sections: [['#sections-tbody', 'rows', 5]],
            roster: [['#student-tbody', 'rows', 5]],
            faculty: [['#faculty-tbody', 'rows', 6]],
            settings: [],
            admins: [['#admin-tbody', 'rows', 2]]
        };

        function fail(key, err) {
            var message = Admin.friendlyDbError(err, 'The data could not be loaded.');

            (FAILURE[key] || []).forEach(function (target) {
                var el = $(target[0]);

                if (!el || !el.querySelector('.skeleton')) {
                    return;
                }
                el.innerHTML =
                    target[1] === 'rows'
                        ? '<tr><td colspan="' +
                          target[2] +
                          '">' +
                          errorBlock(key, message) +
                          '</td></tr>'
                        : errorBlock(key, message);
            });

            var dashed = key === 'stages' ? '[data-stage-count]' : null;
            if (dashed) {
                $$(dashed).forEach(function (node) {
                    if (node.querySelector('.skeleton')) {
                        node.textContent = '—';
                    }
                });
            }
        }

        function track(key, promise) {
            var quiet = quietNext;

            if (!quiet) {
                perKey[key] = (perKey[key] || 0) + 1;
                visible += 1;
                paint();
                announce();
            }

            function settle() {
                if (quiet) {
                    return;
                }
                perKey[key] -= 1;
                visible -= 1;
                paint();
                announce();
            }

            return promise.then(
                function (value) {
                    settle();
                    return value;
                },
                function (err) {
                    settle();
                    fail(key, err);
                    throw err;
                }
            );
        }

        return {
            track: track,
            fail: fail,

            setQuiet: function (value) {
                quietNext = !!value;
            }
        };
    })();
    Admin.Loading = Loading;

    function quietly(load) {
        Loading.setQuiet(true);
        try {
            return load();
        } finally {
            Loading.setQuiet(false);
        }
    }
    Admin.quietly = quietly;

    Admin.RETRY = {};

    function initRetry() {
        document.addEventListener('click', function (event) {
            var btn = event.target.closest('[data-retry]');
            if (!btn) {
                return;
            }
            var load = Admin.RETRY[btn.getAttribute('data-retry')];
            if (!load) {
                return;
            }

            var release = Admin.setBusy(btn, 'Loading…');
            Promise.resolve()
                .then(load)
                .catch(function (err) {
                    Admin.toastErr(
                        'Still couldn’t load it',
                        Admin.friendlyDbError(err, 'Check the connection and try again.')
                    );
                })
                .then(release, release);
        });
    }
    Admin.initRetry = initRetry;

    function sk(text) {
        return '<span class="skeleton skeleton-text">' + Admin.esc(text) + '</span>';
    }

    function skeletonTraits() {
        var one =
            '<div class="trait" aria-hidden="true"><div class="trait-top">' +
            '<span class="trait-name">' +
            sk('Conscientiousness') +
            '</span>' +
            '<span class="trait-val tnum">' +
            sk('00 / 40') +
            '</span></div><div class="bar"></div></div>';
        return '<p class="sr-only">Loading results…</p>' + one + one + one + one + one;
    }
    Admin.skeletonTraits = skeletonTraits;

    function paintSkeletons() {
        function fill(selector, markup) {
            var el = $(selector);
            if (el && !el.children.length) {
                el.innerHTML = markup;
            }
        }

        fill('#sections-tbody', skeletonRows(5, 4));
        fill('#student-tbody', skeletonRows(5, 6));
        fill('#faculty-tbody', skeletonRows(6, 4));
        fill('#admin-tbody', skeletonRows(2, 2));
    }
    Admin.paintSkeletons = paintSkeletons;

    function initScrollRegions() {
        $$('.table-wrap').forEach(function (wrap) {
            if (wrap.hasAttribute('aria-label') && wrap.getAttribute('role') === 'region') {
                return;
            }
            var host = wrap.closest('.card, .modal');
            var title = host && $('.card-title, .modal-title', host);
            wrap.setAttribute('role', 'region');
            wrap.tabIndex = 0;

            if (title && title.id && host.classList.contains('modal')) {
                wrap.setAttribute('aria-labelledby', title.id);
            } else {
                wrap.setAttribute(
                    'aria-label',
                    (title ? title.textContent.trim() : 'Table') + ' — scrolls sideways'
                );
            }
        });
    }
    Admin.initScrollRegions = initScrollRegions;

    var COHORT_COLUMNS =
        'full_name, email, section, group_type, status, current_stage, is_in_game,' +
        ' stage_started_at, active_devices, is_ocean_done, pre_test_score, post_test_score, selected_character';
    Admin.COHORT_COLUMNS = COHORT_COLUMNS;

    var CONSENT_COLUMNS = ', parental_consent, student_assent';
    Admin.CONSENT_COLUMNS = CONSENT_COLUMNS;

    var RAW_SCORE_COLUMNS =
        ', pre_test_raw_score, pre_test_max_score, post_test_raw_score, post_test_max_score';
    Admin.RAW_SCORE_COLUMNS = RAW_SCORE_COLUMNS;
})();
