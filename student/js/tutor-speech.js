/*
 * The tutor.
 * The character, what the tutor says, the face shown for each mood, and the speech bubble.
 */
(function () {
    'use strict';

    var Dash = window.PIADash;

    Dash.tutor = null;

    Dash.tutorKey = null;

    function el(tag, className, text) {
        var node = document.createElement(tag);
        if (className) {
            node.className = className;
        }
        if (text != null) {
            node.textContent = text;
        }
        return node;
    }
    Dash.el = el;

    function clean(text) {
        return String(text == null ? '' : text).replace(/\s*[—–]\s*/g, ', ');
    }
    Dash.clean = clean;

    var bags = {};

    function pickLine(bucket, lines) {
        var pool = [];
        (Array.isArray(lines) ? lines : []).forEach(function (l) {
            var t = String(l || '').trim();
            if (t && pool.indexOf(t) === -1) {
                pool.push(t);
            }
        });
        if (!pool.length) {
            return '';
        }
        if (pool.length === 1) {
            return pool[0];
        }

        var sig = pool.join('␞');
        var bag = bags[bucket];
        if (!bag || bag.sig !== sig || !bag.left.length) {
            var left = pool.slice();
            for (var i = left.length - 1; i > 0; i--) {
                var j = Math.floor(Math.random() * (i + 1));
                var tmp = left[i];
                left[i] = left[j];
                left[j] = tmp;
            }
            if (bag && bag.last && left[0] === bag.last) {
                var swap = left.findIndex(function (l, n) {
                    return n > 0 && l !== bag.last;
                });
                if (swap > 0) {
                    var t2 = left[0];
                    left[0] = left[swap];
                    left[swap] = t2;
                }
            }
            bag = bags[bucket] = { sig: sig, left: left, last: bag ? bag.last : '' };
        }
        bag.last = bag.left.shift();
        return bag.last;
    }
    Dash.pickLine = pickLine;

    function wording() {
        if (!Dash.tutor) {
            return null;
        }
        return Dash.tutor.profiles[Dash.LEARNING_PROFILE] || Dash.tutor.profiles.average;
    }

    function line(type) {
        var bank = wording();
        return bank ? pickLine('say:' + Dash.tutorKey + ':' + type, bank[type]) : '';
    }
    Dash.line = line;

    function reaction(type, fallbackType) {
        var bank = wording();
        var list = bank && bank.reactions && bank.reactions[type];
        if (Array.isArray(list) && list.length) {
            return pickLine('react:' + Dash.tutorKey + ':' + type, list);
        }
        return fallbackType ? line(fallbackType) : '';
    }
    Dash.reaction = reaction;

    function fitSpeech() {
        var box = $('#status-msg'),
            node = $('#agent-speech');
        if (!box || !node) {
            return;
        }
        node.style.fontSize = '';
        var size = parseFloat(getComputedStyle(node).fontSize) || 16;
        var guard = 0;
        while (node.scrollHeight > node.clientHeight + 1 && size > 10.5 && guard++ < 60) {
            size -= 0.5;
            node.style.fontSize = size + 'px';
        }
    }
    Dash.fitSpeech = fitSpeech;

    var figureBox = {};

    function figureCentre(src, done) {
        if (figureBox[src] !== undefined) {
            return done(figureBox[src]);
        }
        var probe = new Image();
        probe.onload = function () {
            var c = 0.5;
            try {
                var w = 96,
                    h = Math.max(1, Math.round((96 * probe.naturalHeight) / probe.naturalWidth));
                var cv = document.createElement('canvas');
                cv.width = w;
                cv.height = h;
                var cx = cv.getContext('2d');
                cx.drawImage(probe, 0, 0, w, h);
                var data = cx.getImageData(0, 0, w, h).data,
                    cols = new Array(w).fill(0);
                for (var y = 0; y < h; y++) {
                    for (var x = 0; x < w; x++) {
                        if (data[(y * w + x) * 4 + 3] > 40) {
                            cols[x]++;
                        }
                    }
                }
                var min = -1,
                    max = -1;
                for (var i = 0; i < w; i++) {
                    if (cols[i] > 1) {
                        if (min < 0) {
                            min = i;
                        }
                        max = i;
                    }
                }
                if (min >= 0) {
                    c = (min + max + 1) / 2 / w;
                }
            } catch (e) {
                c = 0.5;
            }
            figureBox[src] = c;
            done(c);
        };
        probe.onerror = function () {
            figureBox[src] = 0.5;
            done(0.5);
        };
        probe.src = src;
    }

    function centerFigure() {
        var img = $('#agent-img');
        if (!img || !img.naturalWidth) {
            return;
        }
        var src = img.currentSrc || img.src;
        figureCentre(src, function (c) {
            if ((img.currentSrc || img.src) !== src) {
                return;
            }
            var boxW = img.clientWidth,
                boxH = img.clientHeight;
            var w = Math.min(boxW, (boxH * img.naturalWidth) / img.naturalHeight);
            img.style.setProperty('--figure-shift', Math.round(w * (0.5 - c)) + 'px');
        });
    }
    Dash.centerFigure = centerFigure;

    function setSpeech(text) {
        if (window.PIAHintBoard) {
            window.PIAHintBoard.close();
        }
        var node = $('#agent-speech');
        if (node) {
            node.textContent = clean(text);
        }
    }

    var preloaded = {};

    var missing = {};

    var moodToken = 0;

    var currentMood = 'default';

    function knownMood(mood) {
        return Dash.tutor && Dash.tutor.images[mood] ? mood : 'default';
    }

    function moodSrc(mood) {
        var m = knownMood(mood);
        return missing[m] ? Dash.tutor.fallback[m] : Dash.tutor.images[m];
    }
    Dash.moodSrc = moodSrc;

    function guardImage(img) {
        if (!img || img.dataset.guarded) {
            return;
        }
        img.dataset.guarded = '1';
        img.addEventListener('error', function () {
            if (!Dash.tutor) {
                return;
            }
            var shown = img.getAttribute('src');
            Object.keys(Dash.tutor.images).forEach(function (m) {
                if (Dash.tutor.images[m] === shown) {
                    missing[m] = true;
                    if (Dash.tutor.fallback[m] && Dash.tutor.fallback[m] !== shown) {
                        img.setAttribute('src', Dash.tutor.fallback[m]);
                    }
                }
            });
        });
    }
    Dash.guardImage = guardImage;

    function reactToWrong(text) {
        if (window.PIAHintBoard && window.PIAHintBoard.isOpen()) {
            setMood('sad');
        } else {
            speak(text, 'sad');
        }
    }
    Dash.reactToWrong = reactToWrong;

    function setMood(mood) {
        if (!Dash.tutor) {
            return;
        }
        currentMood = knownMood(mood);
        var src = moodSrc(currentMood);
        var img = $('#agent-img');
        if (!img || !src || img.getAttribute('src') === src) {
            return;
        }

        var token = ++moodToken;
        var pre = preloaded[currentMood];
        var ready =
            pre && pre.decode && !missing[currentMood]
                ? pre.decode().catch(function () {})
                : Promise.resolve();
        ready.then(function () {
            if (token === moodToken) {
                img.setAttribute('src', moodSrc(currentMood));
            }
        });
    }

    var talkTimer = null;

    function speak(text, mood) {
        if (text) {
            setSpeech(text);

            var box = $('#status-msg'),
                img = $('#agent-img');
            if (box) {
                box.classList.remove('speaking');
                void box.offsetWidth;
                box.classList.add('speaking');
            }
            if (img) {
                img.classList.add('talking');
                clearTimeout(talkTimer);
                talkTimer = setTimeout(function () {
                    img.classList.remove('talking');
                }, 1400);
            }
        }
        setMood(mood || 'default');
    }
    Dash.speak = speak;

    function applyCharacter(key) {
        var found = window.PIA_TUTORS && window.PIA_TUTORS[key];
        if (!found) {
            return false;
        }

        Dash.tutor = found;
        Dash.tutorKey = key;

        preloaded = {};
        missing = {};
        currentMood = 'default';
        Object.keys(Dash.tutor.images).forEach(function (m) {
            var p = new Image();
            p.onerror = function () {
                missing[m] = true;
                var fb = new Image();
                fb.src = Dash.tutor.fallback[m];
                var shown = $('#agent-img');
                if (shown && currentMood === m) {
                    shown.setAttribute('src', moodSrc(m));
                }
            };
            p.src = Dash.tutor.images[m];
            preloaded[m] = p;
        });

        var label = Dash.TUTOR_NAMES[key] || 'PIA · your tutor';
        var first = label.split(' · ')[0];
        var nameNode = $('#agent-name');
        if (nameNode) {
            nameNode.textContent = label;
        }
        var intro = $('#start-intro');
        if (intro) {
            intro.textContent = 'I’m ' + first + ', your tutor.';
        }
        var lede = $('#start-lede');
        if (lede && WELCOME_LEDE[key]) {
            lede.textContent = WELCOME_LEDE[key];
        }
        ['#agent-img', '#agent-img-start'].forEach(function (sel) {
            var img = $(sel);
            if (!img) {
                return;
            }
            guardImage(img);
            img.setAttribute('src', moodSrc('default'));
            img.setAttribute('alt', 'Your tutor, ' + first);
        });

        return true;
    }
    Dash.applyCharacter = applyCharacter;

    // what each tutor says on the welcome screen, in their own voice
    var WELCOME_LEDE = {
        'pia-open':
            'Ready to explore percentages together? Every problem is a little puzzle, and we will uncover it one clue at a time.',
        'pia-conscientious':
            'Let’s work through percentages step by step. Take your time, and I’ll check each step with you.',
        'pia-extravert':
            'Let’s tackle percentages together! It’s more fun with a partner, so shout whenever you want a hint!',
        'pia-agreeable':
            'I’m so glad you’re here. We’ll go through percentages together, with no pressure. Ask me for a hint anytime.',
        'pia-calm':
            'Take a breath. There’s no rush with percentages, and I’m right here whenever you need a hint.',
        'pia-neutral': 'Let’s practise percentages. You can ask for a hint whenever you need one.'
    };
})();
