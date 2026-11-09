(function () {
    'use strict';

    var motionQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
    var reduceMotion = motionQuery.matches;

    var clamp = function (v, lo, hi) {
        return v < lo ? lo : v > hi ? hi : v;
    };

    var readers = [];
    var running = false;
    var dirty = true;

    function addReader(fn) {
        readers.push(fn);
    }

    function frame() {
        var wantMore = false;

        for (var i = 0; i < readers.length; i++) {
            if (readers[i](dirty) === true) {
                wantMore = true;
            }
        }

        dirty = false;

        if (wantMore) {
            requestAnimationFrame(frame);
        } else {
            running = false;
        }
    }

    function wake() {
        dirty = true;
        if (running) {
            return;
        }
        running = true;
        requestAnimationFrame(frame);
    }

    window.addEventListener('scroll', wake, { passive: true });
    window.addEventListener('resize', wake, { passive: true });
    window.addEventListener('orientationchange', wake, { passive: true });

    var startJobs = [];

    function addStartJob(job) {
        startJobs.push(job);
    }

    function start() {
        startJobs.forEach(function (job) {
            job();
        });
        wake();

        var tokens = getComputedStyle(document.documentElement);
        var token = function (name) {
            return tokens.getPropertyValue(name).trim();
        };
        console.log(
            '%c PIA %c Personal Instructing Agent\n' +
                '  Six agents. One of them teaches the way you think.\n' +
                '  Built at the University of the East. Hello to the one student who checked.',
            'background:' +
                token('--palette-volt') +
                ';color:' +
                token('--palette-ink') +
                ';font-weight:700;padding:2px 6px',
            'color:' + token('--palette-violet')
        );
    }

    window.PIALanding = {
        motionQuery: motionQuery,
        reduceMotion: reduceMotion,
        clamp: clamp,
        addReader: addReader,
        wake: wake,
        addStartJob: addStartJob
    };

    if (document.readyState === 'complete') {
        start();
    } else {
        document.addEventListener('DOMContentLoaded', start);
    }
})();
