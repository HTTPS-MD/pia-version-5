/*
 * Small page-wide helpers.
 * Offline and error banner, backup pictures, light/dark switch, skip link,
 * and the "back to top" button.
 */
(function () {
    'use strict';

    var landing = window.PIALanding;

    function initFallbackImages() {
        $$('img[data-fallback]').forEach(function (img) {
            function useFallback() {
                var fallback = img.getAttribute('data-fallback');
                if (fallback && !img.getAttribute('src').includes('/cast/')) {
                    img.src = fallback;
                }
            }
            img.addEventListener('error', useFallback);
            if (img.complete && img.naturalWidth === 0) {
                useFallback();
            }
        });
    }

    function initWire() {
        var wire = $('#wire');
        if (!wire) {
            return;
        }

        var text = $('[data-wire-text]', wire);
        var offline = false;

        function render() {
            wire.hidden = !offline;
            if (offline && text) {
                text.textContent = "You're offline. The page still works — signing in won't.";
            }
        }

        function goOffline() {
            offline = true;
            render();
        }
        function goOnline() {
            offline = false;
            render();
        }

        window.addEventListener('offline', goOffline);
        window.addEventListener('online', goOnline);
        if (navigator.onLine === false) {
            goOffline();
        }
    }

    function initTheme() {
        var toggles = $$('[data-theme-toggle]');
        if (!toggles.length) {
            return;
        }

        function current() {
            return document.documentElement.getAttribute('data-theme') || 'dark';
        }

        function sync() {
            var dark = String(current() === 'dark');
            toggles.forEach(function (t) {
                t.setAttribute('aria-pressed', dark);
                if (t.classList.contains('theme-toggle')) {
                    t.setAttribute(
                        'aria-label',
                        current() === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'
                    );
                }
            });
        }

        toggles.forEach(function (toggle) {
            toggle.addEventListener('click', function () {
                var next = current() === 'dark' ? 'light' : 'dark';
                document.documentElement.setAttribute('data-theme', next);
                sync();
                try {
                    localStorage.setItem('pia_theme', next);
                } catch (e) {}
            });
        });

        sync();
    }

    function initSkipLink() {
        var link = $('[data-skip]');
        var main = $('#main');
        if (!link || !main) {
            return;
        }

        link.addEventListener('click', function () {
            main.focus({ preventScroll: true });
        });
    }

    function initToTop() {
        var button = $('[data-scroll-top]');
        if (!button) {
            return;
        }
        button.addEventListener('click', function () {
            var calm =
                window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
            window.scrollTo({ top: 0, behavior: calm ? 'auto' : 'smooth' });
            var top = document.getElementById('top');
            if (top) {
                if (!top.hasAttribute('tabindex')) {
                    top.setAttribute('tabindex', '-1');
                }
                top.focus({ preventScroll: true });
            }
        });
    }

    landing.addStartJob(initWire);
    landing.addStartJob(initFallbackImages);
    landing.addStartJob(initTheme);
    landing.addStartJob(initSkipLink);
    landing.addStartJob(initToTop);
})();
