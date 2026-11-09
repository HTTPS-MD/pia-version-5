(function () {
    'use strict';

    var landing = window.PIALanding;
    var reduceMotion = landing.reduceMotion;
    var clamp = landing.clamp;
    var addReader = landing.addReader;
    var wake = landing.wake;

    function splitWords(root) {
        var words = [];

        function walk(node) {
            var kids = Array.prototype.slice.call(node.childNodes);

            kids.forEach(function (child) {
                if (child.nodeType === 3) {
                    var parts = child.nodeValue.split(/(\s+)/);
                    var frag = document.createDocumentFragment();

                    parts.forEach(function (part) {
                        if (!part) {
                            return;
                        }
                        if (/^\s+$/.test(part)) {
                            frag.appendChild(document.createTextNode(part));
                            return;
                        }
                        var span = document.createElement('span');
                        span.className = 'scrub-w';
                        span.appendChild(document.createTextNode(part));
                        frag.appendChild(span);
                        words.push(span);
                    });

                    node.replaceChild(frag, child);
                } else if (child.nodeType === 1) {
                    walk(child);
                }
            });
        }

        walk(root);
        return words;
    }

    function initWordEntrance() {
        $$('[data-lit-words]').forEach(function (head) {
            var words = splitWords(head);
            if (!words.length) {
                return;
            }

            if (reduceMotion) {
                words.forEach(function (w) {
                    w.classList.add('is-lit');
                });
                return;
            }

            var STEP = 55;
            words.forEach(function (w, i) {
                setTimeout(
                    function () {
                        w.classList.add('is-lit');
                    },
                    120 + i * STEP
                );
            });
        });
    }

    function initWordScrub() {
        var heads = $$('[data-scrub-words]');
        if (!heads.length) {
            return;
        }

        if (reduceMotion) {
            return;
        }

        heads.forEach(function (head) {
            var words = splitWords(head);
            if (!words.length) {
                return;
            }

            var lit = -1;
            var active = false;

            if ('IntersectionObserver' in window) {
                new IntersectionObserver(
                    function (entries) {
                        active = entries[0].isIntersecting;
                        if (active) {
                            wake();
                        }
                    },
                    { rootMargin: '25% 0px' }
                ).observe(head);
            } else {
                active = true;
            }

            addReader(function () {
                if (!active) {
                    return false;
                }

                var rect = head.getBoundingClientRect();
                var vh = window.innerHeight;

                var startAt = vh * 0.85;
                var endAt = vh * 0.3;
                var p = clamp((startAt - rect.top) / Math.max(1, startAt - endAt), 0, 1);

                var want = Math.round(p * words.length) - 1;
                if (want === lit) {
                    return false;
                }

                var from = Math.min(lit, want) + 1;
                var to = Math.max(lit, want);
                for (var i = from; i <= to; i++) {
                    if (words[i]) {
                        words[i].classList.toggle('is-lit', i <= want);
                    }
                }
                lit = want;

                return false;
            });
        });
    }

    function initWelcomeType() {
        var host = $('#welcome');
        var text = host && $('.welcome-text', host);
        if (!host || !text || !('IntersectionObserver' in window)) {
            return;
        }
        if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
            return;
        }
        var full = text.getAttribute('data-type') || text.textContent;
        text.textContent = '';
        host.classList.add('is-typing-ready');
        var seen = new IntersectionObserver(
            function (entries) {
                if (!entries[0].isIntersecting) {
                    return;
                }
                seen.disconnect();
                var i = 0;
                host.classList.add('is-typing');
                var timer = setInterval(function () {
                    i += 1;
                    text.textContent = full.slice(0, i);
                    if (i >= full.length) {
                        clearInterval(timer);
                        window.setTimeout(function () {
                            host.classList.remove('is-typing');
                            host.classList.add('is-typed');
                        }, 350);
                    }
                }, 95);
            },
            { threshold: 0.6 }
        );
        seen.observe(host);
    }

    landing.addStartJob(initWordEntrance);
    landing.addStartJob(initWordScrub);
    landing.addStartJob(initWelcomeType);
})();
