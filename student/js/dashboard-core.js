(function () {
    'use strict';

    var Dash = (window.PIADash = {});

    var esc = escapeHTML;
    Dash.esc = esc;

    Dash.LEARNING_PROFILE = 'average';

    var PROFILE_ORDER = ['struggling', 'average', 'outstanding'];
    Dash.PROFILE_ORDER = PROFILE_ORDER;

    Dash.profileCall = 0;

    var TUTOR_NAMES = {
        'pia-open': 'Ava · your tutor',
        'pia-conscientious': 'Cara · your tutor',
        'pia-extravert': 'Theo · your tutor',
        'pia-agreeable': 'Amy · your tutor',
        'pia-calm': 'Kai · your tutor',
        'pia-neutral': 'Noel · your tutor'
    };
    Dash.TUTOR_NAMES = TUTOR_NAMES;

    var TOPICS = {
        1: { short: 'Finding a percentage', name: 'Topic 1 - Finding Percentage' },
        2: { short: 'Percentage increase', name: 'Topic 2 - Percentage Increase' },
        3: { short: 'Percentage decrease', name: 'Topic 3 - Percentage Decrease' }
    };

    function topicOf(n) {
        return TOPICS[n] || TOPICS[1];
    }
    Dash.topicOf = topicOf;

    var TOPIC_TITLES = {
        1: 'Topic 1: Finding Percentage',
        2: 'Topic 2: Percentage Increase',
        3: 'Topic 3: Percentage Decrease'
    };

    function topicTitle(n) {
        return TOPIC_TITLES[n] || TOPIC_TITLES[1];
    }
    Dash.topicTitle = topicTitle;

    var CONFIRM = {
        decimal: {
            label: 'Converted decimal',
            prompt: 'Now write the converted decimal.',
            placeholder: 'e.g. 0.x',
            button: 'Submit conversion',
            error: 'Enter the converted decimal value only.'
        },
        percentage: {
            label: 'Final percentage',
            prompt: 'Now write the final percentage.',
            placeholder: 'a number, with or without %',
            button: 'Submit conversion',
            error: 'Enter the final percentage as a number, with or without the % sign.'
        },
        number: {
            label: 'Final answer',
            prompt: 'Now write the final answer.',
            placeholder: 'a number only',
            button: 'Submit final answer',
            error: 'Enter the final numeric answer only, not the calculation.'
        }
    };
    Dash.CONFIRM = CONFIRM;

    var WORK_PLACEHOLDER = {
        decimal: 'e.g. 0.x',
        percentage: 'a number, with or without %',
        number: 'your calculation or a number'
    };
    Dash.WORK_PLACEHOLDER = WORK_PLACEHOLDER;

    function workKind(p) {
        var label = p.labels && p.labels[p.stepIndex];
        if (label === 'Conversion') {
            return p.questionTopic === 1 ? 'decimal' : 'percentage';
        }
        return 'number';
    }
    Dash.workKind = workKind;

    var EXAMPLE_INTRO = 'Let me show you with a different problem. Tap the arrow to go on.';
    Dash.EXAMPLE_INTRO = EXAMPLE_INTRO;

    var FAST_CORRECT_MS = 12000;
    Dash.FAST_CORRECT_MS = FAST_CORRECT_MS;

    var STREAK_FOR_PRAISE = 3;
    Dash.STREAK_FOR_PRAISE = STREAK_FOR_PRAISE;

    var state = {
        profile: null,
        email: null,
        sessionId: null,
        topic: 1,
        problem: null,
        answered: 0,
        clean: 0,
        streak: 0,
        hintsUsedTotal: 0,
        solved: [],
        errors: [],
        preview: null,
        stepWrong: 0,
        correctRun: 0,
        stepStartedAt: 0,
        submitting: false,
        hinting: false,
        finishing: false,
        offering: false,
        pendingOffer: null,
        starting: false,
        bankEmpty: false,
        expired: false,
        expiring: false,
        closed: false,
        startBlocked: false,
        startLede: '',
        closeTimer: null,
        checking: false,
        restarting: false,
        finished: false,
        inSession: false,
        ended: false
    };
    Dash.state = state;

    window.addEventListener('pia:session-ended', function () {
        state.ended = true;
    });

    var fitQueued = false;

    function fitGameFrame() {
        var frame = $('.game-frame');
        if (!frame || !document.body.classList.contains('is-playing')) {
            return;
        }
        if (window.innerWidth <= 900) {
            frame.style.height = '';
            return;
        }
        frame.style.height = '';
        var top = frame.getBoundingClientRect().top;
        frame.style.height = Math.max(560, Math.floor(window.innerHeight - top - 22)) + 'px';
    }

    function queueFit() {
        if (fitQueued) {
            return;
        }
        fitQueued = true;
        requestAnimationFrame(function () {
            fitQueued = false;
            fitGameFrame();
        });
    }

    window.addEventListener('resize', queueFit);

    if (window.ResizeObserver) {
        new ResizeObserver(queueFit).observe(document.body);
    }

    function showScreen(name) {
        $$('.screen').forEach(function (node) {
            node.classList.toggle('is-active', node.id === 'screen-' + name);
        });

        document.body.classList.toggle('is-playing', name === 'session');
        queueFit();
        window.scrollTo({ top: 0, behavior: 'auto' });

        if (name === 'session') {
            requestAnimationFrame(function () {
                requestAnimationFrame(function () {
                    Dash.fitSpeech();
                    Dash.centerFigure();
                });
            });
        }
    }
    Dash.showScreen = showScreen;

    function setBootText(message) {
        var node = $('#boot-text');
        if (node) {
            node.textContent = message;
        }
    }
    Dash.setBootText = setBootText;

    function reveal() {
        document.body.removeAttribute('data-boot');
        var veil = $('#boot-veil');
        if (veil) {
            setTimeout(function () {
                veil.hidden = true;
            }, 200);
        }
    }
    Dash.reveal = reveal;

    function showGlobalError(message) {
        var banner = $('#global-error-banner');
        if (!banner) {
            return;
        }
        $('#global-error-message').textContent = message;
        banner.hidden = false;
    }
    Dash.showGlobalError = showGlobalError;
})();
