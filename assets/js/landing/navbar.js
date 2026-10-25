/*
 * Navbar.
 * Turns solid on scroll, shows or hides the sign-in buttons, opens the mobile
 * menu, and marks the section you are reading.
 */
(function () {
    'use strict';

    var DESKTOP = window.matchMedia('(min-width: 64rem)');

    function boot() {
        var nav = $('#nav');
        if (!nav) {
            return;
        }

        initSurface(nav);
        initAuthSwap(nav);
        initSheet(nav);
        initScrollspy(nav);
    }

    function initAuthSwap(nav) {
        var hero = $('#hero-cta');
        var controls = $$('.nav-auth', nav);
        var queued = false;
        function update() {
            queued = false;
            var top = nav.getBoundingClientRect().bottom;
            var viewport = window.visualViewport;
            var bottom = viewport ? viewport.offsetTop + viewport.height : window.innerHeight;
            var rect = hero ? hero.getBoundingClientRect() : null;

            var visible =
                !!rect && rect.height > 0 && rect.bottom > top + 12 && rect.top < bottom - 12;
            var show =
                !visible ||
                controls.some(function (button) {
                    return button.contains(document.activeElement);
                });
            if (nav.classList.contains('has-auth') !== show) {
                nav.classList.toggle('has-auth', show);
            }
            controls.forEach(function (button) {
                button.inert = !show;
                button.setAttribute('aria-hidden', String(!show));
            });
        }
        function schedule() {
            if (!queued) {
                queued = true;
                requestAnimationFrame(update);
            }
        }
        window.addEventListener('scroll', schedule, { passive: true });
        window.addEventListener('resize', schedule, { passive: true });
        nav.addEventListener('focusout', schedule);
        if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', schedule);
            window.visualViewport.addEventListener('scroll', schedule);
        }
        if ('ResizeObserver' in window) {
            var size = new ResizeObserver(schedule);
            size.observe(nav);
            if (hero) {
                size.observe(hero);
            }
        }
        new MutationObserver(schedule).observe(nav, {
            attributes: true,
            attributeFilter: ['class']
        });
        new MutationObserver(schedule).observe(document.documentElement, {
            attributes: true,
            attributeFilter: ['data-session']
        });
        update();
    }

    function initSurface(nav) {
        var queued = false;

        function update() {
            queued = false;
            nav.classList.toggle('is-solid', (window.scrollY || window.pageYOffset || 0) > 24);
        }

        window.addEventListener(
            'scroll',
            function () {
                if (queued) {
                    return;
                }
                queued = true;
                requestAnimationFrame(update);
            },
            { passive: true }
        );

        update();
    }

    function initSheet(nav) {
        var burger = $('#nav-burger');
        var sheet = $('#nav-menu');
        var scrim = $('#nav-scrim');
        if (!burger || !sheet) {
            return;
        }

        function isOpen() {
            return nav.classList.contains('is-open');
        }

        function lockScroll() {
            var gap = window.innerWidth - document.documentElement.clientWidth;
            document.documentElement.style.setProperty('--scrollbar-w', gap + 'px');
            document.body.classList.add('is-locked');
        }

        function unlockScroll() {
            if ($('.overlay.is-mounted')) {
                return;
            }
            document.body.classList.remove('is-locked');
            document.documentElement.style.setProperty('--scrollbar-w', '0px');
        }

        function setOpen(open, returnFocus) {
            if (open === isOpen()) {
                return;
            }

            nav.classList.toggle('is-open', open);
            burger.setAttribute('aria-expanded', String(open));
            if (scrim) {
                scrim.classList.toggle('is-open', open);
            }

            if (open) {
                lockScroll();

                var first = $('.nav-link', sheet);
                if (first) {
                    first.focus({ preventScroll: true });
                }
            } else {
                unlockScroll();
                if (returnFocus) {
                    burger.focus({ preventScroll: true });
                }
            }
        }

        burger.addEventListener('click', function () {
            setOpen(!isOpen());
        });

        nav.addEventListener(
            'click',
            function (event) {
                if (!isOpen()) {
                    return;
                }
                if (event.target.closest('a[href^="#"], [data-auth-open]')) {
                    setOpen(false);
                }
            },
            true
        );

        if (scrim) {
            scrim.addEventListener('click', function () {
                setOpen(false);
            });
        }

        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape' && isOpen()) {
                setOpen(false, true);
            }
        });

        nav.addEventListener('focusout', function (event) {
            var next = event.relatedTarget;
            if (isOpen() && next && !nav.contains(next)) {
                setOpen(false);
            }
        });

        var onBreakpoint = function (event) {
            if (event.matches) {
                setOpen(false);
            }
        };
        if (DESKTOP.addEventListener) {
            DESKTOP.addEventListener('change', onBreakpoint);
        } else if (DESKTOP.addListener) {
            DESKTOP.addListener(onBreakpoint);
        }

        $$('.nav-link', sheet).forEach(function (link) {
            link.addEventListener('click', function () {
                var target = document.getElementById(link.getAttribute('href').slice(1));
                if (!target) {
                    return;
                }
                if (!target.hasAttribute('tabindex')) {
                    target.setAttribute('tabindex', '-1');
                }
                setTimeout(function () {
                    target.focus({ preventScroll: true });
                }, 0);
            });
        });
    }

    function initScrollspy(nav) {
        if (!('IntersectionObserver' in window)) {
            return;
        }

        var bySection = {};
        $$('.nav-link[href^="#"]', nav).forEach(function (link) {
            var section = document.getElementById(link.getAttribute('href').slice(1));
            if (section) {
                bySection[section.id] = { link: link, section: section };
            }
        });

        var ids = Object.keys(bySection);
        if (!ids.length) {
            return;
        }

        var current = null;

        function setCurrent(id) {
            if (id === current) {
                return;
            }
            if (current && bySection[current]) {
                bySection[current].link.removeAttribute('aria-current');
            }
            current = id;
            if (id && bySection[id]) {
                bySection[id].link.setAttribute('aria-current', 'location');
            }
        }

        var spy = new IntersectionObserver(
            function (entries) {
                entries.forEach(function (entry) {
                    if (entry.isIntersecting) {
                        setCurrent(entry.target.id);
                    } else if (current === entry.target.id) {
                        setCurrent(null);
                    }
                });
            },
            { rootMargin: '-45% 0px -54% 0px' }
        );

        ids.forEach(function (id) {
            spy.observe(bySection[id].section);
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }
})();
