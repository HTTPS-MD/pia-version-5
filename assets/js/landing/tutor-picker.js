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
