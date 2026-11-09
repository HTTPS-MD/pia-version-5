(function () {
    'use strict';
    var URLS = [
        'https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap',
        'https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500&display=swap'
    ];
    var head = document.head || document.getElementsByTagName('head')[0];
    URLS.forEach(function (href, i) {
        var link = document.createElement('link');
        link.id = 'admin-font-css-' + i;
        link.rel = 'preload';
        link.as = 'style';
        link.href = href;
        var promote = function () {
            link.rel = 'stylesheet';
        };
        link.addEventListener('load', promote);
        window.addEventListener('load', promote);
        head.appendChild(link);
    });
})();
