/* PIA SYSTEM — PRE-PAINT BOOT */
(function () {
    'use strict';

    var theme = 'dark';

    try {
        var saved = localStorage.getItem('pia_theme');
        if (saved === 'light' || saved === 'dark') {
            theme = saved;
        }
    } catch (e) {}

    document.documentElement.setAttribute('data-theme', theme);
    document.documentElement.classList.add('js');

    try {
        for (var i = 0; i < localStorage.length; i++) {
            if (/^sb-.+-auth-token$/.test(localStorage.key(i) || '')) {
                document.documentElement.setAttribute('data-session', 'pending');
                break;
            }
        }
    } catch (e) {}

    var FONT_STYLESHEET =
        'https://fonts.googleapis.com/css2' +
        '?family=Inter:wght@400;500;600;700;800' +
        '&family=JetBrains+Mono:wght@500;700' +
        '&family=Space+Grotesk:wght@700' +
        '&display=swap';

    var FONT_ORIGINS = [
        { href: 'https://fonts.googleapis.com', cors: false },
        { href: 'https://fonts.gstatic.com', cors: true }
    ];

    var head = document.head || document.getElementsByTagName('head')[0];

    FONT_ORIGINS.forEach(function (origin) {
        var hint = document.createElement('link');
        hint.rel = 'preconnect';
        hint.href = origin.href;
        if (origin.cors) {
            hint.crossOrigin = '';
        }
        head.appendChild(hint);
    });

    var fontCss = document.createElement('link');
    fontCss.id = 'font-css';
    fontCss.rel = 'preload';
    fontCss.as = 'style';
    fontCss.href = FONT_STYLESHEET;

    var promote = function () {
        fontCss.rel = 'stylesheet';
    };
    fontCss.addEventListener('load', promote);
    window.addEventListener('load', promote);
    head.appendChild(fontCss);
})();
