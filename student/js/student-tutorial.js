/* PIA SYSTEM — TUTORING TUTORIAL (student-dashboard.html) */
(function () {
    'use strict';

    var SEEN_KEY = 'pia_tutorial_seen_at';

    var STEPS = [
        {
            title: 'Welcome to your tutoring session',
            text: 'You will solve percentage word problems with your tutor, one step at a time. The session has a time limit, shown as Time left, so keep an eye on it.'
        },
        {
            title: 'Work one step at a time',
            text: 'Each problem has a few steps. Type the answer for the step you are on, then press Submit step. The next step appears when you get it right.'
        },
        {
            title: 'Show your working, then the value',
            text: 'You can type a calculation like 0.3 x 60. If it is right, you will be asked to type the final value by itself to finish the step.'
        },
        {
            title: 'Hints are there to help',
            text: 'After two wrong answers on a step, the hint button appears. Each press gives a bit more help, so you can stop as soon as you know what to do.'
        }
    ];

    var sb = null;
    var overlay, titleEl, textEl, stepEl, backBtn, nextBtn, skipBtn, helpBtn, appRoot;
    var index = 0;
    var isOpen = false;
    var returnFocus = null;
    var seenKnown = false;
    var seenThisPage = false;
    var saving = null;
    var spotlightTimer = null;

    function reducedMotion() {
        return !!(
            window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
        );
    }

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
        seenThisPage = true;
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
        backBtn.disabled = index === 0;
        nextBtn.textContent = index === STEPS.length - 1 ? 'Finish' : 'Next';
    }

    function focusables() {
        return Array.prototype.slice.call(overlay.querySelectorAll('button:not([disabled])'));
    }

    function onKey(e) {
        if (!isOpen) {
            return;
        }
        if (e.key === 'Escape') {
            e.preventDefault();
            close(true);
            return;
        }
        if (e.key !== 'Tab') {
            return;
        }
        var nodes = focusables();
        if (!nodes.length) {
            return;
        }
        var first = nodes[0],
            last = nodes[nodes.length - 1];
        if (e.shiftKey && document.activeElement === first) {
            e.preventDefault();
            last.focus();
        } else if (!e.shiftKey && document.activeElement === last) {
            e.preventDefault();
            first.focus();
        }
    }

    function open() {
        if (isOpen) {
            return;
        }
        clearSpotlight();
        isOpen = true;
        index = 0;
        returnFocus = document.activeElement;
        render();
        overlay.classList.add('is-mounted');
        if (appRoot) {
            appRoot.setAttribute('inert', '');
        }
        document.body.classList.add('is-locked');
        void overlay.offsetWidth;
        overlay.classList.add('is-open');
        nextBtn.focus({ preventScroll: true });
    }

    function close(skipped) {
        if (!isOpen) {
            return;
        }
        isOpen = false;
        markSeen();
        overlay.classList.remove('is-open');
        if (appRoot) {
            appRoot.removeAttribute('inert');
        }
        document.body.classList.remove('is-locked');
        setTimeout(
            function () {
                overlay.classList.remove('is-mounted');
            },
            reducedMotion() ? 0 : 160
        );
        if (returnFocus && returnFocus.focus) {
            returnFocus.focus({ preventScroll: true });
        }
        if (skipped) {
            showHelpHint();
        }
    }

    function clearSpotlight() {
        clearTimeout(spotlightTimer);
        if (!helpBtn) {
            return;
        }
        helpBtn.classList.remove('is-spotlight');
        var n = $('.tutorial-callout');
        if (n) {
            n.remove();
        }
    }

    /* After Skip: the How it works button is outlined for a few seconds and a note says
       where it is. The note is announced to screen readers. */
    function showHelpHint() {
        if (!helpBtn) {
            return;
        }
        clearSpotlight();

        var bar = document.querySelector('.learn-bar');
        var note = document.createElement('div');
        note.className = 'tutorial-callout';
        note.setAttribute('role', 'status');
        var inner = document.createElement('p');
        inner.className = 'learn-shell tutorial-callout-text';
        note.appendChild(inner);
        if (bar && bar.parentNode) {
            bar.parentNode.insertBefore(note, bar.nextSibling);
        } else {
            document.body.insertBefore(note, document.body.firstChild);
        }
        setTimeout(function () {
            inner.textContent =
                'You can replay the tutorial any time with the How it works button.';
        }, 50);

        helpBtn.classList.add('is-spotlight');
        spotlightTimer = setTimeout(clearSpotlight, 7000);
    }

    function init(client) {
        sb = client;
        overlay = $('#modal-tutorial');
        helpBtn = $('#tutorial-btn');
        appRoot = $('.learn');
        if (!overlay || !helpBtn) {
            return Promise.resolve();
        }
        titleEl = $('#tutorial-title');
        textEl = $('#tutorial-text');
        stepEl = $('#tutorial-step');
        backBtn = $('#tutorial-back');
        nextBtn = $('#tutorial-next');
        skipBtn = $('#tutorial-skip');

        helpBtn.addEventListener('click', open);
        skipBtn.addEventListener('click', function () {
            close(true);
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
                close(false);
            }
        });
        document.addEventListener('keydown', onKey);
        document.addEventListener(
            'pointerdown',
            function () {
                if (!isOpen) {
                    clearSpotlight();
                }
            },
            true
        );

        return readSeen().then(function (seen) {
            if (seen === null) {
                return;
            }
            seenKnown = seen;
            if (!seen && !seenThisPage) {
                open();
            }
        });
    }

    window.PIATutorial = { init: init, open: open };
})();
