/*
 * Greeting.
 * Shows "Good morning, name" for a signed-in visitor.
 */
(function () {
    'use strict';

    var Auth = window.PIAAuth;

    function partOfDay() {
        var hour = new Date().getHours();
        return hour < 12 ? 'Morning' : hour < 18 ? 'Afternoon' : 'Evening';
    }

    function tidyWord(word) {
        if (word.length < 2 || word !== word.toUpperCase() || word === word.toLowerCase()) {
            return word;
        }
        return word.toLowerCase().replace(/(^|[-'])(\S)/g, function (m, sep, ch) {
            return sep + ch.toUpperCase();
        });
    }

    var STAFF_TITLE = /^(dr|prof|mr|mrs|ms|mx|sir|ma'?am|engr|atty)\.?$/i;

    function greetingName(fullName, email) {
        var name = String(fullName || '').trim();
        var comma = name.indexOf(',');
        if (comma !== -1) {
            name = name.slice(comma + 1).trim() || name.slice(0, comma).trim();
        }

        var words = name.split(/\s+/).filter(Boolean);
        if (!words.length) {
            var local = String(email || '')
                .split('@')[0]
                .split(/[._+\-]/)[0];
            if (!local) {
                return 'there';
            }
            return local.charAt(0).toUpperCase() + local.slice(1).toLowerCase();
        }

        words = words.map(tidyWord);
        if (words.length > 1 && STAFF_TITLE.test(words[0])) {
            return words[0] + ' ' + words[words.length - 1];
        }
        return words[0];
    }
    Auth.greetingName = greetingName;

    function fitGreeting() {
        var title = $('#drop-title');
        if (!title || !title.classList.contains('is-greeting')) {
            return;
        }

        title.style.fontSize = '';

        for (var pass = 0; pass < 4; pass++) {
            var room = title.clientWidth;
            var need = title.scrollWidth;
            if (need <= room + 1) {
                break;
            }
            var size = parseFloat(window.getComputedStyle(title).fontSize);
            title.style.fontSize = Math.floor(size * (room / need) * 0.97) + 'px';
        }
    }

    var fitWired = false;

    function wireGreetingFit() {
        if (fitWired) {
            return;
        }
        fitWired = true;

        var queued = false;
        window.addEventListener('resize', function () {
            if (queued) {
                return;
            }
            queued = true;
            window.requestAnimationFrame(function () {
                queued = false;
                fitGreeting();
            });
        });
        if (document.fonts && document.fonts.ready) {
            document.fonts.ready.then(fitGreeting);
        }
    }

    function writeGreeting(name) {
        var title = $('#drop-title');
        if (!title) {
            return;
        }

        var lines = [
            ['drop-l1', 'Good'],
            ['drop-l2', partOfDay() + ','],
            ['drop-l3', name]
        ];

        title.textContent = '';
        lines.forEach(function (line, n) {
            if (n) {
                title.appendChild(document.createTextNode(' '));
            }
            var row = document.createElement('span');
            row.className = line[0];
            line[1].split(/\s+/).forEach(function (word, i) {
                if (i) {
                    row.appendChild(document.createTextNode(' '));
                }
                var w = document.createElement('span');
                w.className = 'scrub-w';
                w.textContent = word;
                row.appendChild(w);
            });
            title.appendChild(row);
        });
        title.classList.add('is-greeting');

        var kicker = $('.hero-kicker');
        if (kicker) {
            kicker.textContent = 'Personal Instructing Agent';
        }

        fitGreeting();
        wireGreetingFit();
        document.documentElement.setAttribute('data-greeted', '');

        var still =
            window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        $$('.scrub-w', title).forEach(function (w, i) {
            if (still) {
                w.classList.add('is-lit');
                return;
            }
            setTimeout(
                function () {
                    w.classList.add('is-lit');
                },
                120 + i * 55
            );
        });
    }
    Auth.writeGreeting = writeGreeting;
})();
