/*
 * Start-up.
 * Refreshes everything, loads the admin identity, wires the forms and starts the page.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function tracked(key, load) {
        return function () {
            return Admin.Loading.track(key, load.apply(this, arguments));
        };
    }

    Admin.loadCohort = tracked('cohort', Admin.loadCohort);

    Admin.loadSections = tracked('sections', Admin.loadSections);

    Admin.loadRoster = tracked('roster', Admin.loadRoster);

    Admin.loadStageCounters = tracked('stages', Admin.loadStageCounters);

    Admin.loadFaculty = tracked('faculty', Admin.loadFaculty);

    Admin.loadAdmins = tracked('admins', Admin.loadAdmins);

    Admin.loadSettings = tracked('settings', Admin.loadSettings);

    Admin.RETRY = {
        cohort: Admin.loadCohort,
        sections: Admin.loadSections,
        roster: Admin.loadRoster,
        stages: Admin.loadStageCounters,
        faculty: Admin.loadFaculty,
        admins: Admin.loadAdmins,
        settings: Admin.loadSettings
    };

    async function refreshAll(opts) {
        try {
            var jobs;
            try {
                Admin.Loading.setQuiet(opts && opts.quiet);
                jobs = [
                    Admin.loadCohort(),
                    Admin.loadSections(),
                    Admin.loadRoster(),
                    Admin.loadStageCounters(),
                    Admin.loadFaculty(),
                    Admin.loadAdmins(),
                    Admin.loadSettings()
                ];
            } finally {
                Admin.Loading.setQuiet(false);
            }
            await Promise.all(jobs);
            Admin.hideGlobalError();
        } catch (err) {
            console.error('Dashboard data failed to load:', err);
            Admin.showGlobalError(
                err && err.message
                    ? 'Some data failed to load: ' + err.message
                    : 'Some data failed to load. Please refresh the page.'
            );
        }
    }
    Admin.refreshAll = refreshAll;

    async function initAdminIdentity(email) {
        Admin.state.adminEmail = email;

        var name = email.split('@')[0];
        var res = await sb.from('profiles').select('full_name').eq('email', email).maybeSingle();
        if (res.data && res.data.full_name) {
            name = res.data.full_name.trim();
        }

        Admin.state.adminName = name;

        $('#admin-name').textContent = name;
        $('#admin-email').textContent = email;
        $('#profile-name').textContent = name;
        $('#profile-email').textContent = email;
        $('#admin-initials').textContent = Admin.initialsOf(name, email);
    }

    function initForms() {
        Admin.initTutorFields();
        $('#edit-student-form').addEventListener('submit', Admin.handleUpdateStudent);
        $$('#edit-student-form [data-score-test]').forEach(function (input) {
            input.addEventListener('input', function () {
                Admin.paintScorePreview(input.getAttribute('data-score-test'));
            });
        });
        $('#add-professor-form').addEventListener('submit', Admin.handleRegisterProfessor);
        $('#add-admin-form').addEventListener('submit', Admin.handleAddAdmin);
        Admin.initChangePassword();

        $('#new-section-form').addEventListener('submit', async function (event) {
            event.preventDefault();
            var name = $('#ns-name').value.trim();

            if (!name) {
                Admin.setFieldError('ns-name', 'Section name is required.');
                return;
            }

            var duplicate = Admin.state.sections.some(function (s) {
                return s.name.toLowerCase() === name.toLowerCase();
            });
            if (duplicate) {
                Admin.setFieldError('ns-name', 'A section with that name already exists.');
                return;
            }
            Admin.setFieldError('ns-name', '');

            var release = Admin.setBusy($('#ns-submit'), 'Creating…');
            var res = await sb.from('sections').insert([{ name: name }]);
            release();

            if (res.error) {
                Admin.setFieldError(
                    'ns-name',
                    Admin.friendlyDbError(res.error, 'Could not create the section.')
                );
                Admin.toastErr(
                    'Section not created',
                    Admin.friendlyDbError(res.error, 'Insert rejected.')
                );
                return;
            }

            Admin.closeModal('modal-new-section');
            $('#new-section-form').reset();
            Admin.toastOk('Section created', name + ' is ready for enrolment.');
            document.dispatchEvent(new Event('pia:students-added'));
            await refreshAll();
            Admin.showSection(name);
        });

        $('#scores-save').addEventListener('click', Admin.saveBatchScores);
        $('#scores-tbody').addEventListener('input', function (event) {
            var pair = event.target.closest('.score-pair');
            if (pair) {
                Admin.paintScorePair(pair);
            }
        });
        ['pre', 'post'].forEach(function (test) {
            $('#scores-max-' + test).addEventListener('input', function () {
                Admin.repaintScores(test);
            });
        });
    }

    async function boot() {
        if (typeof sb === 'undefined' || !sb) {
            Admin.setBootText('Database connection failed.');
            Admin.showGlobalError('Database connection failed. Please refresh the page.');
            return;
        }

        var email;
        Admin.setBootText('Verifying administrator access…');

        var sessionRes;
        try {
            sessionRes = await sb.auth.getSession();
        } catch (err) {
            sessionRes = { error: err, data: { session: null } };
        }

        if (sessionRes.error || !sessionRes.data.session) {
            Admin.setBootText('Your session ended. Taking you to sign in…');
            endStaffSession('ended');
            return;
        }

        email = sessionRes.data.session.user.email;

        var profileRes;
        try {
            profileRes = await sb.from('profiles').select('role').eq('email', email).maybeSingle();
        } catch (err) {
            profileRes = { error: { message: (err && err.message) || 'Network error' } };
        }

        if (profileRes.error && isNetworkFailure(profileRes.error)) {
            Admin.setBootText('Can’t reach the server. Check the connection, then reload.');
            Admin.showGlobalError(
                'Can’t reach the server. Your session is kept; reload when you are back online.'
            );
            return;
        }

        if (profileRes.error || !profileRes.data) {
            var current = await isSessionCurrentOnServer();
            console.error(
                'Admin console: access check refused.',
                profileRes.error || 'no profile row',
                'session current:',
                current
            );
            Admin.setBootText('Your session ended. Taking you to sign in…');
            endStaffSession(current === false ? 'revoked' : 'ended');
            return;
        }

        var role = String(profileRes.data.role || '')
            .trim()
            .toLowerCase();
        if (role !== 'admin') {
            Admin.setBootText('This console is for administrators. Taking you to yours…');
            window.location.replace(
                role === 'teacher'
                    ? '../../teacher/html/teacher-dashboard.html'
                    : '../../student/html/waiting-room.html'
            );
            return;
        }

        try {
            localStorage.setItem('pia_user_email', email);
        } catch (err) {}

        PIAAdminShell.init({
            go: Admin.switchView,
            openModal: Admin.openModal,
            openStudent: Admin.openStudentByEmail,
            openSection: Admin.showSection,
            getSections: function () {
                return Admin.state.sections;
            },
            searchStudents: Admin.searchStudentsRemote,
            signOut: Admin.signOut,
            isModalOpen: function () {
                return Admin.openLayers.length > 0;
            }
        });
        Admin.initRouter();
        Admin.initModals();
        Admin.initInfoTips();
        Admin.initCustomSelects();
        Admin.initRoster();
        Admin.initSectionsTable();
        Admin.initDrawerActions();
        Admin.initFaculty();
        Admin.initGates();
        initForms();
        Admin.initMathTask();
        Admin.initRetry();
        Admin.initScrollRegions();
        Admin.paintSkeletons();

        Admin.setBootText('Loading dashboard…');
        await initAdminIdentity(email);

        Admin.revealApp();

        await refreshAll();

        Admin.setupRealtime();
        Admin.startLiveSessionsTimer();

        startStaffSessionWatch();

        if (typeof startIdleWatchdog === 'function') {
            startIdleWatchdog({ limitMs: 30 * 60 * 1000, onTimeout: Admin.signOut });
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }
})();
