/*
 * Videos.
 * The background video in the hero and the "how it works" video.
 */
(function () {
    'use strict';

    var landing = window.PIALanding;
    var reduceMotion = landing.reduceMotion;
    var motionQuery = landing.motionQuery;

    function initHeroVideo() {
        var hero = $('#hero');
        var video = $('#hero-video');
        var toggle = $('#hero-video-toggle');
        if (!hero || !video) {
            return;
        }

        var conn = navigator.connection || {};
        if (conn.saveData === true || /(^|-)2g$/.test(conn.effectiveType || '')) {
            return;
        }

        var STORE = 'pia_hero_video';
        var choice = null;
        try {
            choice = localStorage.getItem(STORE);
        } catch (e) {}

        var userPaused = choice === 'paused' || (choice !== 'playing' && reduceMotion);
        var onScreen = true;
        var label = toggle ? $('[data-video-label]', toggle) : null;

        video.muted = true;

        function render() {
            if (!toggle) {
                return;
            }
            var paused = video.paused;
            toggle.classList.toggle('is-paused', paused);
            if (label) {
                label.textContent = paused ? 'Play background video' : 'Pause background video';
            }
        }

        function sync() {
            var want = !userPaused && onScreen && !document.hidden;

            if (want && video.paused) {
                var attempt = video.play();

                if (attempt && attempt.catch) {
                    attempt.catch(render);
                }
            } else if (!want && !video.paused) {
                video.pause();
            }
        }

        video.addEventListener('play', render);
        video.addEventListener('pause', render);

        var sources = $$('source', video);
        if (sources.length && toggle) {
            sources[sources.length - 1].addEventListener('error', function () {
                toggle.hidden = true;
            });
        }

        if (toggle) {
            toggle.hidden = false;
            toggle.addEventListener('click', function () {
                userPaused = !video.paused;
                choice = userPaused ? 'paused' : 'playing';
                try {
                    localStorage.setItem(STORE, choice);
                } catch (e) {}
                sync();
                render();
            });
        }

        if ('IntersectionObserver' in window) {
            new IntersectionObserver(function (entries) {
                onScreen = entries[0].isIntersecting;
                sync();
            }).observe(hero);
        }

        document.addEventListener('visibilitychange', sync);

        if (motionQuery.addEventListener) {
            motionQuery.addEventListener('change', function (event) {
                if (event.matches && choice !== 'playing') {
                    userPaused = true;
                    sync();
                }
            });
        }

        render();
        sync();
    }

    function initHowVideo() {
        var video = $('#how-video');
        var play = $('#how-play');
        if (!video || !play) {
            return;
        }
        var frame = play.parentNode;
        frame.classList.add('has-play');
        video.controls = false;
        function start() {
            video.controls = true;
            frame.classList.add('is-playing');
            var started = video.play();
            if (started && started.catch) {
                started.catch(function () {
                    frame.classList.remove('is-playing');
                    video.controls = false;
                });
            }
        }
        play.addEventListener('click', start);
        video.addEventListener('ended', function () {
            frame.classList.remove('is-playing');
            video.controls = false;
            video.currentTime = 0;
        });
        video.addEventListener('click', function () {
            if (!frame.classList.contains('is-playing')) {
                start();
            }
        });
    }

    landing.addStartJob(initHeroVideo);
    landing.addStartJob(initHowVideo);
})();
