/*
 * Effects that follow the scroll.
 * Sections that fade in, the hover highlight, the rising footer card and the
 * privacy section burst.
 */
(function () {
    'use strict';

    var landing = window.PIALanding;
    var reduceMotion = landing.reduceMotion;
    var clamp = landing.clamp;
    var addReader = landing.addReader;

    function initReveals() {
        var targets = $$('[data-reveal]');
        if (!targets.length) {
            return;
        }

        if (reduceMotion || !('IntersectionObserver' in window)) {
            targets.forEach(function (el) {
                el.classList.add('is-in', 'is-done');
            });
            return;
        }

        var io = new IntersectionObserver(
            function (entries) {
                entries.forEach(function (entry) {
                    if (!entry.isIntersecting) {
                        return;
                    }
                    var el = entry.target;
                    el.classList.add('is-in');
                    io.unobserve(el);

                    el.addEventListener('transitionend', function done(e) {
                        if (e.propertyName !== 'transform') {
                            return;
                        }
                        el.classList.add('is-done');
                        el.removeEventListener('transitionend', done);
                    });
                });
            },
            {
                rootMargin: '0px 0px -12% 0px',
                threshold: 0.01
            }
        );

        targets.forEach(function (el) {
            io.observe(el);
        });
    }

    function initHoverIntent() {
        if (!window.matchMedia('(hover: hover) and (pointer: fine)').matches) {
            return;
        }

        var DWELL = 150;

        $$('[data-hover-intent]').forEach(function (el) {
            var timer = null;

            el.addEventListener('mouseenter', function () {
                timer = setTimeout(function () {
                    el.classList.add('is-keen');
                }, DWELL);
            });

            el.addEventListener('mouseleave', function () {
                clearTimeout(timer);
                timer = null;
                el.classList.remove('is-keen');
            });

            el.addEventListener('focusin', function () {
                el.classList.add('is-keen');
            });
            el.addEventListener('focusout', function () {
                el.classList.remove('is-keen');
            });
        });
    }

    function initFooterRise() {
        var card = $('.foot-card');
        var foot = card && card.closest('.foot');
        if (!card || !foot || reduceMotion) {
            return;
        }

        var last = -1;

        addReader(function () {
            var top = foot.getBoundingClientRect().top + card.offsetTop;
            var height = card.offsetHeight;
            var vh = window.innerHeight || document.documentElement.clientHeight;

            var span = Math.min(height * 0.68, vh * 0.6);
            var t = Math.max(0, Math.min(1, (vh - top) / span));

            var eased = Math.round((1 - Math.pow(1 - t, 3)) * 200) / 200;
            if (eased !== last) {
                last = eased;
                card.style.setProperty('--rise', String(eased));
            }
            return false;
        });
    }

    function initPrivacyBurst() {
        var host = $('#privacy');
        if (!host || reduceMotion) {
            return;
        }
        var last = -1;
        addReader(function () {
            var rect = host.getBoundingClientRect();
            var vh = window.innerHeight || document.documentElement.clientHeight;
            var p = clamp((vh - rect.top) / (vh / 2 + rect.height / 2), 0, 1);

            var e = p * p * (3 - 2 * p);
            if (Math.abs(e - last) < 0.002) {
                return false;
            }
            last = e;
            host.style.setProperty('--burst', e.toFixed(3));
            return false;
        });
    }

    landing.addStartJob(initReveals);
    landing.addStartJob(initHoverIntent);
    landing.addStartJob(initFooterRise);
    landing.addStartJob(initPrivacyBurst);
})();
