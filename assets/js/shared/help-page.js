/*
 * Help pages (teacher and admin).
 * Shows each step's screenshot only once its file has loaded, so a step without
 * a picture reads as plain text. The topic list scrolls to a step with buttons,
 * not links, because the pages route on the URL hash.
 */
(function () {
    'use strict';

    function init(root) {
        var steps = Array.prototype.slice.call(root.querySelectorAll('.help-step'));
        var tocButtons = Array.prototype.slice.call(root.querySelectorAll('[data-help-go]'));

        root.querySelectorAll('.help-shot[data-shot]').forEach(function (shot) {
            var img = new Image();
            img.alt = shot.getAttribute('data-alt') || '';
            img.decoding = 'async';
            img.addEventListener('load', function () {
                shot.appendChild(img);
                shot.hidden = false;
                shot.closest('.help-step').classList.add('has-shot');
            });
            img.src = shot.getAttribute('data-shot');
        });

        var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        tocButtons.forEach(function (btn) {
            btn.addEventListener('click', function () {
                var target = document.getElementById(btn.getAttribute('data-help-go'));
                if (target) {
                    target.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'start' });
                }
            });
        });

        if (!('IntersectionObserver' in window) || !steps.length) {
            return;
        }
        var observer = new IntersectionObserver(
            function (entries) {
                entries.forEach(function (entry) {
                    if (!entry.isIntersecting) {
                        return;
                    }
                    tocButtons.forEach(function (btn) {
                        var on = btn.getAttribute('data-help-go') === entry.target.id;
                        btn.classList.toggle('is-active', on);
                        if (on) {
                            btn.setAttribute('aria-current', 'true');
                        } else {
                            btn.removeAttribute('aria-current');
                        }
                    });
                });
            },
            { rootMargin: '-20% 0px -65% 0px' }
        );
        steps.forEach(function (step) {
            observer.observe(step);
        });
    }

    document.addEventListener('DOMContentLoaded', function () {
        var root = document.querySelector('.help-layout');
        if (root) {
            init(root);
        }
    });
})();
