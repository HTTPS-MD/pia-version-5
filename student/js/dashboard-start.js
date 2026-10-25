/*
 * Start-up.
 * Checks the student, loads everything and wires the buttons.
 */
(function () {
    'use strict';

    var Dash = window.PIADash;

    async function boot() {
        if (typeof sb === 'undefined' || !sb) {
            Dash.setBootText('Could not connect.');
            Dash.showGlobalError('Could not reach the server. Please refresh the page.');
            return;
        }

        Dash.setBootText('Checking your session…');
        var profile = await enforceStudentStage('dash');
        if (!profile) {
            return;
        }

        Dash.state.profile = profile;
        Dash.state.email = profile.email;

        window.PIA_HAS_ACTIVE_WORK = function () {
            return Dash.state.inSession;
        };

        var stageRes = await sb.rpc('set_student_stage', { p_stage: 'Tutoring Dashboard' });
        if (stageRes.data && stageRes.data.granted === false) {
            window.location.replace('waiting-room.html');
            return;
        }
        startStageHeartbeat('Tutoring Dashboard');

        /* Deliberately narrow: full_name, selected_character and section only.
           ocean_* must not enter this page — see the header note. */
        var me = await sb
            .from('profiles')
            .select('full_name, selected_character, section')
            .eq('email', Dash.state.email)
            .maybeSingle();

        var name = (me.data && me.data.full_name) || Dash.state.email.split('@')[0];
        var firstName = name.trim().split(/\s+/)[0];

        Dash.setHello('Hi, ', firstName);

        Dash.initModals();

        var speechNode = $('#agent-speech');
        if (speechNode && window.MutationObserver) {
            new MutationObserver(Dash.fitSpeech).observe(speechNode, {
                childList: true,
                characterData: true,
                subtree: true
            });
        }
        var agentImg = $('#agent-img');
        if (agentImg) {
            agentImg.addEventListener('load', Dash.centerFigure);
        }
        var stageNode = $('.mentor-agent-stage');
        if (stageNode && window.ResizeObserver) {
            new ResizeObserver(function () {
                Dash.centerFigure();
                Dash.fitSpeech();
            }).observe(stageNode);
        }
        var resizeTimer = null;
        window.addEventListener('resize', function () {
            clearTimeout(resizeTimer);
            resizeTimer = setTimeout(function () {
                Dash.fitSpeech();
                Dash.centerFigure();
            }, 120);
        });
        $('#hint-btn').addEventListener('click', Dash.handleHint);
        $('#signout-btn').addEventListener('click', Dash.signOut);
        $('#start-btn').addEventListener('click', handleStart);
        $('#offer-accept').addEventListener('click', function () {
            Dash.answerOffer(true);
        });
        $('#offer-stay').addEventListener('click', function () {
            Dash.answerOffer(false);
        });
        $('#closed-signout').addEventListener('click', Dash.signOut);
        Dash.paintSolved();
        Dash.paintErrors();
        Dash.paintHintButton();

        if (!Dash.applyCharacter(me.data && me.data.selected_character)) {
            $('#start-btn').disabled = true;
            Dash.state.startBlocked = true;
            Dash.showGlobalError(
                me.data && me.data.selected_character
                    ? 'Your tutor could not be loaded. Please tell your teacher.'
                    : 'Your tutor has not been assigned yet. Please tell your teacher.'
            );
            Dash.reveal();
            return;
        }

        var peek = await sb.rpc('resume_or_start_game_session');
        if (peek.error) {
            $('#start-btn').disabled = true;
            Dash.state.startBlocked = true;
            Dash.showGlobalError('Your session could not be loaded. Please refresh the page.');
        } else if (peek.data && peek.data.session_id) {
            Dash.applySession(peek.data);

            $('#fact-progress').textContent = Dash.state.answered;
            $('#start-chips').hidden = !(Dash.state.answered > 0);

            var where =
                'You are on topic ' +
                Dash.state.topic +
                ': ' +
                Dash.topicOf(Dash.state.topic).short.toLowerCase() +
                '.';
            if (peek.data.resumed) {
                $('#start-btn-label').textContent = 'Continue';
                Dash.setHello('Welcome back, ', firstName);
                $('#start-lede').textContent =
                    (Dash.state.answered > 0
                        ? 'You’ve answered ' +
                          Dash.state.answered +
                          ' question' +
                          (Dash.state.answered === 1 ? '' : 's') +
                          ' so far. '
                        : '') + 'Pick up right where you left off.';
            } else if (Dash.state.topic > 1) {
                $('#start-lede').textContent =
                    where +
                    ' The session has a time limit, and you can ask ' +
                    'for a hint whenever you’re stuck.';
            }
        }

        if (Dash.state.sessionId && peek.data && peek.data.resumed) {
            var past = await sb.rpc('get_session_history', { p_session_id: Dash.state.sessionId });
            if (!past.error && past.data) {
                Dash.state.solved = Array.isArray(past.data.solved) ? past.data.solved : [];
                Dash.state.errors = Array.isArray(past.data.errors) ? past.data.errors : [];
                Dash.state.hintsUsedTotal = Number(past.data.hints_total) || 0;
                Dash.paintSolved();
                Dash.paintErrors();
            }
        }

        await Dash.checkTutoring();
        Dash.watchTutoring();

        Dash.reveal();

        if (window.PIATutorial) {
            window.PIATutorial.init(sb).catch(function () {});
        }

        if (typeof registerChannel === 'function') {
            registerChannel('student-dash-lock', function (channel) {
                return channel
                    .on(
                        'postgres_changes',
                        {
                            event: 'UPDATE',
                            schema: 'public',
                            table: 'settings',
                            filter: 'key=eq.stage_dash'
                        },
                        function (payload) {
                            var open = payload.new.value === true || payload.new.value === 'true';
                            if (open) {
                                return;
                            }
                            if (window.PIA_HAS_ACTIVE_WORK()) {
                                showStageClosedNotice();
                                return;
                            }
                            window.location.replace('waiting-room.html');
                        }
                    )
                    .subscribe();
            });
        }
    }

    async function handleStart() {
        if (Dash.state.starting) {
            return;
        }
        Dash.state.starting = true;
        var release = Dash.setBusy($('#start-btn'), 'Starting…');

        var ok = Dash.state.sessionId ? true : await Dash.startOrResume();
        if (!ok) {
            release();
            Dash.state.starting = false;
            return;
        }

        await sb
            .from('profiles')
            .update({
                is_in_game: true,
                current_difficulty:
                    'Topic ' + Dash.state.topic + ' · ' + Dash.topicOf(Dash.state.topic).short
            })
            .eq('email', Dash.state.email);

        release();
        Dash.state.inSession = true;
        Dash.initLeaveGuard();
        Dash.showScreen('session');
        Dash.speak(
            Dash.line('greet') ||
                'Let’s begin. Read the problem carefully, then work it out step by step.',
            'default'
        );
        await Dash.nextProblem();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }
})();
