/*
 * Tutor picker.
 * Choose one of the six tutors: the picture, text and tabs change together,
 * and the arrow, Home and End keys work.
 */
(function () {
    'use strict';

    var root = document.getElementById('agent-select');
    if (!root) {
        return;
    }

    var tabs = Array.prototype.slice.call(root.querySelectorAll('.roster-item[role="tab"]'));
    if (!tabs.length) {
        return;
    }

    var counter = document.getElementById('select-counter');

    function figureFor(id) {
        return root.querySelector('.stage-figure[data-figure="' + id + '"]');
    }
    function panelFor(id) {
        return document.getElementById('panel-' + id);
    }

    function select(tab, opts) {
        var id = tab.getAttribute('data-agent');
        if (!id) {
            return;
        }

        tabs.forEach(function (t) {
            var on = t === tab;
            var tid = t.getAttribute('data-agent');

            t.setAttribute('aria-selected', on ? 'true' : 'false');
            t.tabIndex = on ? 0 : -1;

            var fig = figureFor(tid);
            var pan = panelFor(tid);
            if (fig && !on && fig._reset) {
                fig._reset();
            }
            if (fig) {
                fig.hidden = !on;
            }
            if (pan) {
                pan.hidden = !on;
            }
        });

        if (counter) {
            var n = tabs.indexOf(tab) + 1;
            counter.textContent = (n < 10 ? '0' : '') + n;
        }

        if (opts && opts.focus) {
            tab.focus();
        }
    }

    tabs.forEach(function (tab) {
        tab.addEventListener('click', function () {
            select(tab, { focus: false });
        });
    });

    Array.prototype.forEach.call(
        root.querySelectorAll('.stage-figure[data-poses]'),
        function (fig) {
            var poses = fig.getAttribute('data-poses').split(/\s+/).filter(Boolean);
            var img = fig.querySelector('.stage-art img');
            if (poses.length < 2 || !img) {
                return;
            }

            var preloaded = false;
            function preload() {
                if (preloaded) {
                    return;
                }
                preloaded = true;
                poses.forEach(function (src) {
                    new Image().src = src;
                });
            }
            if (!fig.hidden) {
                if ('IntersectionObserver' in window) {
                    var near = new IntersectionObserver(
                        function (entries) {
                            if (entries[0].isIntersecting) {
                                near.disconnect();
                                preload();
                            }
                        },
                        { rootMargin: '600px 0px' }
                    );
                    near.observe(fig);
                } else {
                    preload();
                }
            }
            if ('MutationObserver' in window) {
                new MutationObserver(function () {
                    if (!fig.hidden) {
                        preload();
                    }
                }).observe(fig, { attributes: true, attributeFilter: ['hidden'] });
            }

            var tab = tabs.filter(function (t) {
                return t.getAttribute('data-agent') === fig.getAttribute('data-figure');
            })[0];
            var name = tab ? tab.querySelector('.roster-name').textContent.trim() : 'the tutor';

            var poke = document.createElement('button');
            poke.type = 'button';
            poke.className = 'stage-poke';
            poke.setAttribute('aria-label', 'Hear more from ' + name);
            fig.appendChild(poke);

            var lines = (fig.getAttribute('data-lines') || '').split('|').filter(Boolean);
            var panel = panelFor(fig.getAttribute('data-figure'));
            var say = panel ? panel.querySelector('.detail-line') : null;

            var i = 0;
            function show() {
                img.src = poses[i];
                if (say && lines.length) {
                    say.textContent = lines[i] || lines[0];
                    say.classList.remove('is-talking');
                    void say.offsetWidth;
                    say.classList.add('is-talking');
                }
            }

            fig._reset = function () {
                if (i === 0) {
                    return;
                }
                i = 0;
                img.src = poses[0];
                if (say && lines.length) {
                    say.textContent = lines[0];
                }
            };

            poke.addEventListener('click', function () {
                i = (i + 1) % poses.length;
                show();
                fig.classList.add('has-poked');
                fig.classList.remove('is-poked');
                void fig.offsetWidth;
                fig.classList.add('is-poked');
            });
        }
    );

    document.addEventListener('click', function (e) {
        var link = e.target.closest ? e.target.closest('[data-pick]') : null;
        if (!link) {
            return;
        }
        var id = link.getAttribute('data-pick');
        var tab = tabs.filter(function (t) {
            return t.getAttribute('data-agent') === id;
        })[0];
        if (tab) {
            select(tab, { focus: false });
        }
    });

    root.addEventListener('keydown', function (e) {
        var current = document.activeElement;
        var i = tabs.indexOf(current);
        if (i === -1) {
            return;
        }

        var next = null;

        switch (e.key) {
            case 'ArrowDown':
            case 'ArrowRight':
                next = tabs[(i + 1) % tabs.length];
                break;
            case 'ArrowUp':
            case 'ArrowLeft':
                next = tabs[(i - 1 + tabs.length) % tabs.length];
                break;
            case 'Home':
                next = tabs[0];
                break;
            case 'End':
                next = tabs[tabs.length - 1];
                break;
            default:
                return;
        }

        e.preventDefault();
        select(next, { focus: true });
    });
})();
