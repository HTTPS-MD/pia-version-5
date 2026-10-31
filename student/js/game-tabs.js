// phones: the game is split into three tabs along the bottom (lesson, error log, solved questions)
(function () {
    var frame = document.querySelector('.game-frame');
    var tabs = document.querySelectorAll('.game-tab');
    if (!frame || !tabs.length) return;

    function show(name) {
        frame.setAttribute('data-tab', name);
        Array.prototype.forEach.call(tabs, function (btn) {
            var on = btn.getAttribute('data-tab') === name;
            btn.classList.toggle('is-active', on);
            btn.setAttribute('aria-pressed', on ? 'true' : 'false');
        });
        window.scrollTo(0, 0);
    }

    Array.prototype.forEach.call(tabs, function (btn) {
        btn.addEventListener('click', function () {
            show(btn.getAttribute('data-tab'));
        });
    });
    show('lesson');
})();
