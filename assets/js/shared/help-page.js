(function () {
    'use strict';

    document.addEventListener('DOMContentLoaded', function () {
        document.querySelectorAll('.help-shot[data-shot]').forEach(function (shot) {
            var img = new Image();
            img.alt = shot.getAttribute('data-alt') || '';
            img.decoding = 'async';
            img.addEventListener('load', function () {
                shot.appendChild(img);
                shot.hidden = false;
            });
            img.src = shot.getAttribute('data-shot');
        });
    });
})();
