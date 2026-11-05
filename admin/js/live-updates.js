/*
 * Live updates.
 * Refreshes the page when data changes, and searches students across sections.
 */
(function () {
    'use strict';

    var Admin = window.PIAAdmin;

    function isUserBusy() {
        var active = document.activeElement;
        var typing =
            active &&
            (active.tagName === 'INPUT' ||
                active.tagName === 'TEXTAREA' ||
                active.tagName === 'SELECT');
        return !!(typing || Admin.openLayers.length);
    }

    function scheduleRefresh() {
        if (Admin.deferredRefresh) {
            return;
        }
        Admin.deferredRefresh = true;

        clearTimeout(Admin.refreshTimer);
        Admin.refreshTimer = setTimeout(function () {
            Admin.deferredRefresh = false;

            if (isUserBusy()) {
                Admin.backoffMs = Math.min(Admin.backoffMs * 2, 8000);
                scheduleRefresh();
                return;
            }

            Admin.backoffMs = 1000;
            Admin.refreshAll({ quiet: true });
        }, Admin.backoffMs);
    }

    function flushDeferredRefresh() {
        if (!Admin.deferredRefresh || isUserBusy()) {
            return;
        }
        clearTimeout(Admin.refreshTimer);
        Admin.deferredRefresh = false;
        Admin.backoffMs = 1000;
        Admin.refreshAll({ quiet: true });
    }
    Admin.flushDeferredRefresh = flushDeferredRefresh;

    function qbLiveRefresh() {
        if (Admin.qb.status !== 'ready') {
            return;
        }
        clearTimeout(Admin.qb.liveTimer);
        Admin.qb.liveTimer = setTimeout(function () {
            Admin.quietly(Admin.loadMathTask).catch(function (err) {
                console.error('Math task refresh failed:', err);
            });
        }, 150);
    }

    function setupRealtime() {
        if (typeof registerChannel !== 'function') {
            console.warn('registerChannel unavailable — realtime updates are off.');
            return;
        }

        registerChannel('admin-realtime-profiles', function (channel) {
            return channel
                .on(
                    'postgres_changes',
                    { event: '*', schema: 'public', table: 'profiles' },
                    function (payload) {
                        scheduleRefresh();

                        if (payload.new && payload.new.email) {
                            Admin.applyPresence(
                                payload.new.email,
                                (payload.new.active_devices || []).length > 0
                            );
                        }
                    }
                )
                .subscribe();
        });

        registerChannel('admin-realtime-app-config', function (channel) {
            return channel
                .on(
                    'postgres_changes',
                    { event: '*', schema: 'public', table: 'app_config' },
                    qbLiveRefresh
                )
                .subscribe();
        });
        registerChannel('admin-realtime-question-bank', function (channel) {
            return channel
                .on(
                    'postgres_changes',
                    { event: '*', schema: 'public', table: 'question_bank' },
                    qbLiveRefresh
                )
                .subscribe();
        });
        setInterval(function () {
            if (!document.hidden) {
                qbLiveRefresh();
            }
        }, 10000);

        registerChannel('admin-realtime-settings', function (channel) {
            return channel
                .on(
                    'postgres_changes',
                    { event: '*', schema: 'public', table: 'settings' },
                    function () {
                        Admin.quietly(Admin.loadSettings).catch(function (err) {
                            console.error('Settings reload failed:', err);
                        });
                    }
                )
                .subscribe();
        });
    }
    Admin.setupRealtime = setupRealtime;

    function isMissingTable(error) {
        return (
            !!error &&
            (error.code === '42P01' ||
                error.code === 'PGRST205' ||
                /does not exist|could not find the table/i.test(error.message || ''))
        );
    }
    Admin.isMissingTable = isMissingTable;

    async function searchStudentsRemote(term, signal) {
        var t = Admin.sanitizeFilterTerm(term).toLowerCase();
        if (!t) {
            return [];
        }
        var query = sb
            .from('profiles')
            .select('full_name, email, section')
            .not('role', 'in', Admin.STAFF_ROLES)
            .or('full_name.ilike.%' + t + '%,email.ilike.%' + t + '%')
            .order('full_name', { ascending: true })
            .limit(6);
        if (signal && typeof query.abortSignal === 'function') {
            query = query.abortSignal(signal);
        }
        var res = await query;
        if (res.error) {
            throw res.error;
        }
        return res.data || [];
    }
    Admin.searchStudentsRemote = searchStudentsRemote;

    async function openStudentByEmail(email) {
        if (!Admin.findStudent(email)) {
            var res = await sb.from('profiles').select('*').eq('email', email).maybeSingle();
            if (res.error || !res.data) {
                Admin.toastErr(
                    'Could not open the profile',
                    Admin.friendlyDbError(res.error, 'That student was not found.')
                );
                return;
            }
            Admin.state.cohort.push(res.data);
        }
        Admin.switchView('students');
        Admin.openStudentDrawer(email);
    }
    Admin.openStudentByEmail = openStudentByEmail;

    var QB_TOPICS = {
        EASY: { num: 1, short: 'Finding %', title: 'Finding a percentage' },
        MEDIUM: { num: 2, short: '% Increase', title: 'Percentage increase' },
        HARD: { num: 3, short: '% Decrease', title: 'Percentage decrease' }
    };
    Admin.QB_TOPICS = QB_TOPICS;

    var QB_ORDER = ['EASY', 'MEDIUM', 'HARD'];
    Admin.QB_ORDER = QB_ORDER;

    var QB_POINTS_MAX = 500;
    Admin.QB_POINTS_MAX = QB_POINTS_MAX;

    var QB_STEP_LABELS = {
        EASY: ['Conversion', 'Multiplication'],
        MEDIUM: ['Subtraction', 'Division', 'Conversion'],
        HARD: ['Subtraction', 'Division', 'Conversion']
    };
    Admin.QB_STEP_LABELS = QB_STEP_LABELS;

    var QB_COLUMNS = 'id, difficulty, question, final_answer, hint, points';
    Admin.QB_COLUMNS = QB_COLUMNS;
})();
