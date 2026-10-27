/*
 * Loading data.
 * Reads the students, stage times, sections, professors and settings from the database.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function isMissingColumn(error) {
        return (
            !!error &&
            (error.code === '42703' ||
                error.code === 'PGRST204' ||
                /column .* does not exist|could not find the .* column/i.test(error.message || ''))
        );
    }
    Admin.isMissingColumn = isMissingColumn;

    Admin.loadCohort = async function loadCohort() {
        Admin.state.loading.cohort = true;

        function readProfiles(columns) {
            return sb.from('profiles').select(columns).not('role', 'in', STAFF_ROLES).limit(2000);
        }

        var both = await Promise.all([
            readProfiles(Admin.COHORT_COLUMNS + Admin.CONSENT_COLUMNS + Admin.RAW_SCORE_COLUMNS),
            sb.from('ocean_submissions').select('email').limit(5000)
        ]);
        var res = both[0];
        var results = both[1];

        if (res.error && isMissingColumn(res.error)) {
            console.warn(
                '[PIA] raw score columns missing; apply migration 0034. Cohort read without them.'
            );
            res = await readProfiles(Admin.COHORT_COLUMNS + Admin.CONSENT_COLUMNS);
        }
        if (res.error && isMissingColumn(res.error)) {
            console.warn(
                '[PIA] consent columns missing; apply migration 0033. Cohort read without them.'
            );
            res = await readProfiles(Admin.COHORT_COLUMNS);
        }

        Admin.state.loading.cohort = false;

        if (res.error) {
            throw res.error;
        }
        if (results.error) {
            throw results.error;
        }

        Admin.state.resultEmails = {};
        (results.data || []).forEach(function (row) {
            Admin.state.resultEmails[String(row.email || '').toLowerCase()] = true;
        });

        Admin.state.cohort = res.data || [];
        await loadStageTimes();
        Admin.state.cohortLoaded = true;
        Admin.renderSections();
        Admin.renderGateAccess();
        Admin.renderFaculty($('#faculty-search') ? $('#faculty-search').value : '');
    };

    async function loadStageTimes() {
        var res = await sb
            .from('student_stage_time')
            .select(
                'student_email, ocean_time, character_select_time, tutoring_time, heartbeat_stage, last_heartbeat_timestamp'
            )
            .limit(5000);

        if (res.error) {
            if (Admin.isMissingTable(res.error)) {
                Admin.state.stageTimes = null;
            } else {
                Admin.state.stageTimesStale = true;
                console.error('[PIA] stage times could not be read:', res.error);
            }
            return;
        }

        var byEmail = {};
        (res.data || []).forEach(function (row) {
            byEmail[String(row.student_email || '').toLowerCase()] = row;
        });
        Admin.state.stageTimes = byEmail;
        Admin.state.stageTimesStale = false;
    }
    Admin.loadStageTimes = loadStageTimes;

    Admin.loadSections = async function loadSections() {
        var res = await sb.from('sections').select('name').order('name', { ascending: true });
        if (res.error) {
            throw res.error;
        }

        Admin.state.sections = res.data || [];
        Admin.state.sectionsLoaded = true;
        fillSectionSelects();
        Admin.renderSections();
    };

    var STAFF_ROLES = '("admin","teacher")';
    Admin.STAFF_ROLES = STAFF_ROLES;

    function allSectionsOn() {
        return !!Admin.state.allSections;
    }
    Admin.allSectionsOn = allSectionsOn;

    function applyGroupFilter(query) {
        if (Admin.state.filters.section && !allSectionsOn()) {
            query = query.eq('section', Admin.state.filters.section);
        }
        var g = Admin.state.filters.group;
        if (g === 'experimental') {
            return query.in('group_type', ['assigned', 'non-assigned', 'neutral']);
        }
        if (g === 'assigned' || g === 'non-assigned' || g === 'neutral' || g === 'control') {
            return query.eq('group_type', g);
        }
        return query;
    }

    function applyStageFilter(query, stage) {
        if (stage === null || stage === undefined || stage === '') {
            return query;
        }
        if (stage === 'Active Game') {
            return query.eq('is_in_game', true);
        }
        return query.eq('current_stage', stage).eq('is_in_game', false);
    }

    var rosterTicket = 0;

    Admin.loadRoster = async function loadRoster() {
        var ticket = ++rosterTicket;
        var tbody = $('#student-tbody');
        if (!Admin.state.rosterPage.length) {
            tbody.innerHTML = Admin.skeletonRows(5, 6);
        }
        Admin.state.loading.roster = true;
        $('#pager-info').textContent = 'Loading…';

        var query = sb
            .from('profiles')
            .select('*', { count: 'exact' })
            .not('role', 'in', STAFF_ROLES);

        var term = Admin.sanitizeFilterTerm(Admin.state.filters.search).toLowerCase();
        if (term) {
            query = query.or('full_name.ilike.%' + term + '%,email.ilike.%' + term + '%');
        }
        query = applyStageFilter(applyGroupFilter(query), Admin.state.filters.stage);

        var start = (Admin.state.page - 1) * Admin.PAGE_SIZE;
        query = query
            .range(start, start + Admin.PAGE_SIZE - 1)
            .order('full_name', { ascending: true });

        var res = await query;
        if (ticket !== rosterTicket) {
            return;
        }
        Admin.state.loading.roster = false;

        if (res.error) {
            tbody.innerHTML =
                '<tr><td colspan="5"><div class="state-block region-error">' +
                '<p class="state-title">Couldn’t load the students</p>' +
                '<p class="state-desc">' +
                Admin.esc(Admin.friendlyDbError(res.error, 'Unknown database error.')) +
                '</p>' +
                '<button class="btn btn-secondary btn-sm" type="button" data-retry="roster">Try again</button>' +
                '</div></td></tr>';
            $('#student-empty').classList.add('is-hidden');
            $('#pager-info').textContent = 'Could not load the students.';
            $('#page-prev').disabled = true;
            $('#page-next').disabled = true;
            return;
        }

        var total = res.count || 0;
        var pages = Math.max(1, Math.ceil(total / Admin.PAGE_SIZE));

        if (total > 0 && Admin.state.page > pages) {
            Admin.state.page = pages;
            Admin.loadRoster();
            return;
        }

        Admin.state.rosterPage = res.data || [];
        Admin.state.totalStudents = total;
        Admin.renderRoster();
    };

    var counterTicket = 0;

    var COUNTER_KEYS = ['all', 'OCEAN', 'Character Selection', 'Tutoring Dashboard', 'Active Game'];

    Admin.loadStageCounters = async function loadStageCounters() {
        var ticket = ++counterTicket;
        var base = function (stage) {
            var q = sb
                .from('profiles')
                .select('email', { count: 'exact', head: true })
                .not('role', 'in', STAFF_ROLES);
            return applyStageFilter(applyGroupFilter(q), stage === 'all' ? null : stage);
        };

        try {
            var results = await Promise.all(
                COUNTER_KEYS.map(function (key) {
                    return base(key);
                })
            );
            if (ticket !== counterTicket) {
                return;
            }

            var failed = null;
            results.forEach(function (res, index) {
                var node = $('[data-stage-count="' + COUNTER_KEYS[index] + '"]');
                if (res.error) {
                    failed = res.error;
                }
                if (node) {
                    node.textContent = res.error ? '—' : res.count || 0;
                }
            });
            if (failed) {
                throw failed;
            }
            var allCount = results[0].count || 0;
            $('#nav-count-students').textContent = allCount;
        } catch (err) {
            console.error('Stage counters failed:', err);
            Admin.Loading.fail('stages', err);
        }
    };

    async function loadFacultyOcean() {
        var emails = (Admin.state.faculty || [])
            .map(function (f) {
                return String(f.email || '').toLowerCase();
            })
            .filter(Boolean);
        Admin.state.facultyOcean = {};
        if (!emails.length) {
            return;
        }
        try {
            var both = await Promise.all([
                sb.from('profiles').select('email, is_ocean_done').in('email', emails),
                sb
                    .from('ocean_submissions')
                    .select('email, ocean_e, ocean_a, ocean_c, ocean_n, ocean_o, submitted_at')
                    .in('email', emails)
                    .order('submitted_at', { ascending: false })
            ]);
            var map = {};
            emails.forEach(function (e) {
                map[e] = { done: false, row: null };
            });
            (both[0].data || []).forEach(function (r) {
                var m = map[String(r.email).toLowerCase()];
                if (m) {
                    m.done = !!r.is_ocean_done;
                }
            });
            (both[1].data || []).forEach(function (r) {
                var m = map[String(r.email).toLowerCase()];
                if (m && !m.row) {
                    m.row = r;
                }
            });
            Admin.state.facultyOcean = both[0].error || both[1].error ? {} : map;
        } catch (e) {
            Admin.state.facultyOcean = {};
        }
    }

    Admin.loadFaculty = async function loadFaculty() {
        var res = await sb.from('professors').select('*').order('name', { ascending: true });
        if (res.error) {
            throw res.error;
        }

        Admin.state.faculty = res.data || [];
        await loadFacultyOcean();
        $('#nav-count-faculty').textContent = Admin.state.faculty.length;
        Admin.renderFaculty($('#faculty-search') ? $('#faculty-search').value : '');
        Admin.renderSections();
    };

    Admin.loadSettings = async function loadSettings() {
        var both = await Promise.all([
            sb.from('settings').select('key, value'),
            sb
                .from('stage_overrides')
                .select('stage, section, granted_count, granted_by, granted_at')
                .order('section', { ascending: true })
        ]);
        var res = both[0];
        var overrides = both[1];
        if (res.error) {
            throw res.error;
        }

        (res.data || []).forEach(function (row) {
            if (!row.key || row.key.indexOf('stage_') !== 0) {
                return;
            }
            var key = row.key.replace('stage_', '');
            var gate = Admin.GATES.filter(function (g) {
                return g.key === key;
            })[0];
            if (gate) {
                gate.open = row.value === true || row.value === 'true';
            }
        });

        Admin.state.overridesMissing = !!overrides.error && Admin.isMissingTable(overrides.error);
        if (overrides.error && !Admin.state.overridesMissing) {
            console.error('[PIA] stage overrides could not be read:', overrides.error);
        }
        Admin.state.overrides = overrides.error ? null : overrides.data || [];
        await Admin.loadTutoringSchedules();

        Admin.renderGateAccess();
    };

    function fillSectionSelects() {
        var markup = Admin.state.sections
            .map(function (section) {
                return (
                    '<option value="' +
                    Admin.esc(section.name) +
                    '">' +
                    Admin.esc(section.name) +
                    '</option>'
                );
            })
            .join('');

        $$('[data-section-select]').forEach(function (select) {
            var current = select.value;
            select.innerHTML = markup || '<option value="">No sections yet</option>';
            if (current) {
                select.value = current;
            }
        });

        var filter = $('#section-filter');
        if (filter) {
            var keep = Admin.state.filters.section;
            filter.innerHTML = '<option value="">All sections</option>' + markup;
            if (
                keep &&
                !Admin.state.sections.some(function (sec) {
                    return sec.name === keep;
                })
            ) {
                Admin.state.filters.section = keep = '';
                Admin.state.page = 1;
                if (Admin.state.sectionsLoaded) {
                    Admin.loadRoster();
                    Admin.loadStageCounters();
                }
            }
            filter.value = keep;
            Admin.refreshCustomSelect('section-filter');
        }
    }
})();
