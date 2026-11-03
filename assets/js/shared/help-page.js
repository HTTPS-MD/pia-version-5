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

        if (!steps.length) {
            return;
        }
        var ticking = false;
        function update() {
            ticking = false;
            var line = window.innerHeight * 0.35;
            var atEnd = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4;
            var current = steps[0];
            steps.forEach(function (step) {
                if (step.getBoundingClientRect().top <= line) {
                    current = step;
                }
            });
            if (atEnd) {
                current = steps[steps.length - 1];
            }
            tocButtons.forEach(function (btn) {
                var on = btn.getAttribute('data-help-go') === current.id;
                btn.classList.toggle('is-active', on);
                if (on) {
                    btn.setAttribute('aria-current', 'true');
                } else {
                    btn.removeAttribute('aria-current');
                }
            });
        }
        function onScroll() {
            if (!ticking) {
                ticking = true;
                window.requestAnimationFrame(update);
            }
        }
        window.addEventListener('scroll', onScroll, { passive: true });
        window.addEventListener('resize', onScroll);
        update();
    }

    document.addEventListener('DOMContentLoaded', function () {
        var root = document.querySelector('.help-layout');
        if (root) {
            init(root);
        }
    });
})();
