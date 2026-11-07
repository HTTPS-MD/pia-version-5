/* PIA SYSTEM — TUTORING TUTORIAL (student-dashboard.html) */
(function () {
    'use strict';

    var SEEN_KEY = 'pia_tutorial_seen_at';

    // To show a picture on a step, put the file in assets/images/tutorial/ and set image to its name,
    // for example image: 'step-1.webp', and alt to a short description of it.
    var IMAGE_DIR = '../../assets/images/tutorial/';

    var STEPS = [
        {
            title: 'Welcome to your tutoring session',
            image: '',
            alt: '',
            text: 'You will solve percentage word problems with your tutor, one step at a time. The session has a time limit, shown as Time left, so keep an eye on it.'
        },
        {
            title: 'Work one step at a time',
            image: '',
            alt: '',
            text: 'Each problem has a few steps. Type the answer for the step you are on, then press Submit step. The next step appears when you get it right.'
        },
        {
            title: 'Show your working, then the value',
            image: '',
            alt: '',
            text: 'You can type a calculation like 0.3 x 60. If it is right, you will be asked to type the final value by itself to finish the step.'
        },
        {
            title: 'Hints are there to help',
            image: '',
            alt: '',
            text: 'After two wrong answers on a step, the hint button appears. Each press gives a bit more help, so you can stop as soon as you know what to do.'
        }
    ];

    var sb = null;
    var card, content, titleEl, textEl, stepEl, imgEl, backBtn, nextBtn;
    var index = 0;
    var seenKnown = false;
    var saving = null;

    function readSeen() {
        if (!sb || !sb.auth || typeof sb.auth.getUser !== 'function') {
            return Promise.resolve(null);
        }
        return sb.auth.getUser().then(
            function (res) {
                if (res.error || !res.data || !res.data.user) {
                    return null;
                }
                var meta = res.data.user.user_metadata || {};
                return !!meta[SEEN_KEY];
            },
            function () {
                return null;
            }
        );
    }

    function markSeen() {
        if (seenKnown || saving || !sb || !sb.auth || typeof sb.auth.updateUser !== 'function') {
            return;
        }
        var data = {};
        data[SEEN_KEY] = new Date().toISOString();
        saving = sb.auth
            .updateUser({ data: data })
            .then(
                function (res) {
                    if (!res.error) {
                        seenKnown = true;
                    }
                },
                function () {}
            )
            .then(function () {
                saving = null;
            });
    }

    function render() {
        var step = STEPS[index];
        stepEl.textContent = 'Step ' + (index + 1) + ' of ' + STEPS.length;
        titleEl.textContent = step.title;
        textEl.textContent = step.text;
        if (step.image) {
            imgEl.src = IMAGE_DIR + step.image;
            imgEl.alt = step.alt || '';
            imgEl.hidden = false;
        } else {
            imgEl.hidden = true;
            imgEl.removeAttribute('src');
        }
        backBtn.hidden = index === 0;
        nextBtn.textContent = index === STEPS.length - 1 ? 'Start' : 'Next';
    }

    // the white card shows the tutorial first; the last step starts the session
    function showTutorial() {
        index = 0;
        render();
        content.hidden = true;
        card.hidden = false;
    }

    // the last step's button is Start: it ends the tutorial and starts the session (the Start card stays if that is not possible)
    function finish() {
        markSeen();
        card.hidden = true;
        content.hidden = false;
        var start = $('#start-btn');
        if (start && !start.disabled) {
            start.click();
        }
    }

    function init(client) {
        sb = client;
        card = $('#tutorial-card');
        content = $('#start-content');
        if (!card || !content) {
            return Promise.resolve();
        }
        titleEl = $('#tutorial-title');
        textEl = $('#tutorial-text');
        stepEl = $('#tutorial-step');
        imgEl = $('#tutorial-img');
        backBtn = $('#tutorial-back');
        nextBtn = $('#tutorial-next');

        imgEl.addEventListener('error', function () {
            imgEl.hidden = true;
        });
        backBtn.addEventListener('click', function () {
            if (index > 0) {
                index -= 1;
                render();
            }
        });
        nextBtn.addEventListener('click', function () {
            if (index < STEPS.length - 1) {
                index += 1;
                render();
            } else {
                finish();
            }
        });

        return readSeen().then(function (seen) {
            if (seen === null) {
                return;
            }
            seenKnown = seen;
            if (!seen) {
                showTutorial();
            }
        });
    }

    window.PIATutorial = { init: init };
})();
