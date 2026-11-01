/*
 * Admin basics.
 * Small helpers, scores, shared state, the loading screen, and the page router (Sections, Math Task, Settings).
 */
(function () {
    'use strict';

    var Admin = (window.PIAAdmin = {});

    var esc = escapeHTML;
    Admin.esc = esc;

    var toInt =
        typeof safeInt === 'function'
            ? safeInt
            : function (value, fallback) {
                  var n = parseInt(value, 10);
                  return Number.isFinite(n) ? n : fallback;
              };
    Admin.toInt = toInt;

    var OCEAN_MAX = typeof OCEAN_SCORE_MAX !== 'undefined' ? OCEAN_SCORE_MAX : 40;
    Admin.OCEAN_MAX = OCEAN_MAX;

    function debounce(fn, wait) {
        var timer = null;
        return function () {
            var args = arguments,
                self = this;
            clearTimeout(timer);
            timer = setTimeout(function () {
                fn.apply(self, args);
            }, wait || 200);
        };
    }
    Admin.debounce = debounce;

    function icon(name, extraClass) {
        return (
            '<svg class="icon ' + (extraClass || '') + '"><use href="#i-' + name + '"></use></svg>'
        );
    }
    Admin.icon = icon;

    function initialsOf(fullName, email) {
        var source = (fullName || '').trim().replace(/^(Dr|Prof|Mr|Mrs|Ms|Engr|Atty)\.?\s+/i, '');
        if (!source) {
            return (email || '?').slice(0, 2).toUpperCase();
        }
        var parts = source.split(/\s+/);
        if (parts.length === 1) {
            return parts[0].slice(0, 2).toUpperCase();
        }
        return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
    }
    Admin.initialsOf = initialsOf;

    function pct(part, total) {
        return total > 0 ? Math.round((part / total) * 100) : 0;
    }
    Admin.pct = pct;

    function normalizeEmail(raw) {
        return (raw || '').trim().toLowerCase();
    }
    Admin.normalizeEmail = normalizeEmail;

    function friendlyDbError(error, fallback) {
        if (!error) {
            return fallback;
        }
        var msg = error.message || '';
        /* The database's own refusals ("PIA: an administrator cannot ...",
           migration 0031) already say exactly why; pass them through. */
        if (/^PIA:\s*/.test(msg)) {
            return msg.replace(/^PIA:\s*/, '');
        }
        if (error.code === '23505' || /duplicate key|already exists/i.test(msg)) {
            return 'An account already uses this email. Only one account per email is allowed.';
        }
        if (error.code === '42501' || /permission denied|row-level security/i.test(msg)) {
            return 'You do not have permission for this action. Make sure you are signed in as an admin.';
        }
        return msg || fallback;
    }
    Admin.friendlyDbError = friendlyDbError;

    var TEST_LABELS = { pre: 'pre-test', post: 'post-test' };
    Admin.TEST_LABELS = TEST_LABELS;

    function transmute(raw, max) {
        return Math.round(((raw / max) * 50 + 50 + Number.EPSILON) * 100) / 100;
    }

    function formatScore(n) {
        return n == null || n === '' ? '—' : String(Math.round(Number(n) * 100) / 100);
    }
    Admin.formatScore = formatScore;

    function sameNumber(a, b) {
        if (a == null || a === '' || b == null || b === '') {
            return (a == null || a === '') && (b == null || b === '');
        }
        return Number(a) === Number(b);
    }
    Admin.sameNumber = sameNumber;

    function readScorePair(rawValue, maxValue, rawDecides) {
        var rawText = String(rawValue == null ? '' : rawValue).trim();
        var maxText = String(maxValue == null ? '' : maxValue).trim();
        if (!rawText && (!maxText || rawDecides)) {
            return { ok: true, raw: null, max: null, score: null };
        }
        if (!rawText) {
            return { ok: false, error: 'Enter the raw score too, or clear both fields.' };
        }
        if (!maxText) {
            return { ok: false, error: 'Enter the highest possible score too.' };
        }

        var raw = Number(rawText);
        var max = Number(maxText);
        if (!Number.isFinite(raw) || !Number.isFinite(max)) {
            return { ok: false, error: 'Scores must be numbers.' };
        }
        if (max <= 0) {
            return { ok: false, error: 'The highest possible score must be more than 0.' };
        }
        if (raw < 0 || raw > max) {
            return {
                ok: false,
                error: 'The raw score must be between 0 and ' + formatScore(max) + '.'
            };
        }
        return { ok: true, raw: raw, max: max, score: transmute(raw, max) };
    }
    Admin.readScorePair = readScorePair;

    function scoreParts(s, test) {
        var score = s[test + '_test_score'];
        var raw = s[test + '_test_raw_score'];
        var max = s[test + '_test_max_score'];
        if (score == null) {
            return { value: 'n/a', detail: '' };
        }
        if (raw == null || max == null) {
            return { value: formatScore(score), detail: 'Legacy' };
        }
        return { value: formatScore(score), detail: formatScore(raw) + ' / ' + formatScore(max) };
    }
    Admin.scoreParts = scoreParts;

    var MIGRATION_MISSING =
        'This database is not fully set up for this, so nothing was saved. Ask whoever maintains the database to finish its setup, then try again.';
    Admin.MIGRATION_MISSING = MIGRATION_MISSING;

    function isEmail(value) {
        return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
    }
    Admin.isEmail = isEmail;

    function sanitizeFilterTerm(raw) {
        return (raw || '').replace(/[,()*]/g, ' ').trim();
    }
    Admin.sanitizeFilterTerm = sanitizeFilterTerm;

    function generateSecurePassword(length) {
        var chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%';
        var bytes = new Uint32Array(length || 20);
        crypto.getRandomValues(bytes);
        return Array.from(bytes, function (b) {
            return chars[b % chars.length];
        }).join('');
    }
    Admin.generateSecurePassword = generateSecurePassword;

    function describeDevice(deviceId) {
        var id = String(deviceId || '');
        if (id.indexOf('Android') !== -1) {
            return { label: 'Android smartphone', glyph: 'phone' };
        }
        if (id.indexOf('iPad') !== -1) {
            return { label: 'iPad tablet', glyph: 'tablet' };
        }
        if (id.indexOf('iOS') !== -1) {
            return { label: 'iOS device', glyph: 'phone' };
        }
        if (id.indexOf('macOS') !== -1) {
            return { label: 'macOS computer', glyph: 'laptop' };
        }
        if (id.indexOf('Windows') !== -1) {
            return { label: 'Windows PC', glyph: 'monitor' };
        }
        return { label: 'Unknown device', glyph: 'monitor' };
    }
    Admin.describeDevice = describeDevice;

    function activationRedirect() {
        return emailLinkTo('assets/html/sign-up.html');
    }
    Admin.activationRedirect = activationRedirect;

    var STAGE_META = {
        OCEAN: { label: 'OCEAN test', badge: 'badge-warn', fill: 'f-warn' },
        'Character Selection': { label: 'Choose tutor', badge: 'badge', fill: 'f-muted' },
        'Tutoring Dashboard': { label: 'Game', badge: '', fill: 'f-muted' },
        'Active Game': { label: 'Active session', badge: 'badge-accent', fill: '' },
        'Thank You': { label: 'Thank you page', badge: 'badge', fill: 'f-muted' }
    };
    Admin.STAGE_META = STAGE_META;

    var CONDITIONS = {
        assigned: { short: 'EXP · Assigned', badge: 'badge-accent', family: 'experimental' },
        'non-assigned': { short: 'EXP · Free choice', badge: 'badge', family: 'experimental' },
        neutral: { short: 'EXP · Neutral', badge: 'badge', family: 'experimental' },
        control: { short: 'CTRL · Traditional', badge: '', family: 'control' }
    };
    Admin.CONDITIONS = CONDITIONS;

    var GATES = [
        {
            key: 'ocean',
            stage: 'Stage 1',
            title: 'OCEAN personality test',
            open: false,
            label: 'OCEAN'
        },
        {
            key: 'char',
            stage: 'Stage 2',
            title: 'Choose a tutor',
            open: false,
            label: 'Character Selection'
        },
        {
            key: 'dash',
            stage: 'Stage 3',
            title: 'Game',
            open: false,
            label: 'Tutoring Dashboard'
        }
    ];
    Admin.GATES = GATES;

    var PAGE_SIZE = 10;
    Admin.PAGE_SIZE = PAGE_SIZE;

    var state = {
        adminEmail: null,
        adminName: 'Admin',
        sections: [],
        cohort: [],
        resultEmails: {},
        rosterPage: [],
        faculty: [],
        admins: [],
        totalStudents: 0,
        page: 1,
        filters: { section: '', group: 'all', stage: null, search: '' },
        allSections: false,
        activeStudent: null,
        activeSection: null,
        deviceDiag: [],
        overrides: undefined,
        overridesMissing: false,
        schedules: undefined,
        gateSelected: { ocean: [], char: [], dash: [] },
        cohortLoaded: false,
        sectionsLoaded: false,
        stageTimes: undefined,
        loading: { roster: false, cohort: false }
    };
    Admin.state = state;

    function setBootText(message) {
        var node = $('#boot-text');
        if (node) {
            node.textContent = message;
        }
    }
    Admin.setBootText = setBootText;

    function revealApp() {
        document.body.removeAttribute('data-boot');
        var veil = $('#boot-veil');
        if (!veil) {
            return;
        }
        setTimeout(function () {
            veil.hidden = true;
        }, 200);
    }
    Admin.revealApp = revealApp;

    function showGlobalError(message) {
        var banner = $('#global-error-banner');
        var text = $('#global-error-message');
        if (!banner || !text) {
            return;
        }
        text.textContent = message;
        banner.hidden = false;
    }
    Admin.showGlobalError = showGlobalError;

    function hideGlobalError() {
        var banner = $('#global-error-banner');
        if (banner) {
            banner.hidden = true;
        }
    }
    Admin.hideGlobalError = hideGlobalError;

    function closeMobileNav() {
        PIAAdminShell.closeMobileNav();
    }

    var VIEWS = ['students', 'faculty', 'mathtask', 'settings'];

    function switchView(view) {
        if (view === 'controls') {
            view = 'students';
        }
        if (view === 'live') {
            view = 'students';
        }
        if (view === 'profile') {
            view = 'settings';
        }
        if (view === 'overview') {
            view = 'students';
        }
        if (view === 'sections' || view === 'faculty') {
            view = 'students';
        }
        if (VIEWS.indexOf(view) === -1) {
            view = 'students';
        }

        $$('[data-view-panel]').forEach(function (panel) {
            panel.classList.toggle('is-hidden', panel.getAttribute('data-view-panel') !== view);
        });

        PIAAdminShell.setRoute(view);

        try {
            sessionStorage.setItem('pia.admin.view', view);
        } catch (err) {}
        if (window.location.hash !== '#' + view) {
            history.replaceState(null, '', '#' + view);
        }

        if (view === 'students') {
            Admin.loadStageCounters();
        }
        if (view === 'mathtask' && Admin.qb.status !== 'ready' && Admin.qb.status !== 'loading') {
            Admin.loadMathTask();
        }

        closeMobileNav();
        window.scrollTo({ top: 0, behavior: 'auto' });
    }
    Admin.switchView = switchView;

    function initRouter() {
        var fromHash = (window.location.hash || '').replace('#', '');
        var stored = '';
        try {
            stored = sessionStorage.getItem('pia.admin.view') || '';
        } catch (err) {}
        switchView(fromHash || stored || 'students');

        window.addEventListener('hashchange', function () {
            var target = (window.location.hash || '').replace('#', '');
            if (target === 'sections') {
                target = 'students';
            }
            if (target && VIEWS.indexOf(target) !== -1) {
                switchView(target);
            }
        });
    }
    Admin.initRouter = initRouter;

    Admin.openLayers = [];

    var Z_OVERLAY_BASE = 100;
    Admin.Z_OVERLAY_BASE = Z_OVERLAY_BASE;

    Admin.lastFocused = null;

    var FOCUSABLE =
        'button:not([disabled]), a[href], input:not([disabled]), select:not([disabled]),' +
        ' textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
    Admin.FOCUSABLE = FOCUSABLE;
})();
