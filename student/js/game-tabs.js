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

    var speech = document.getElementById('agent-speech');
    var box = document.getElementById('status-msg');
    var recall = document.getElementById('tutor-recall');
    var phone = window.matchMedia('(max-width: 900px)');
    var hideTimer = null;
    var SHOW_MS = 15000;

    function closeTutor() {
        clearTimeout(hideTimer);
        frame.classList.remove('tutor-open');
    }
    function openTutor() {
        if (!phone.matches) return;
        frame.classList.add('tutor-open');
        clearTimeout(hideTimer);
        hideTimer = setTimeout(closeTutor, SHOW_MS);
    }

    if (speech) {
        new MutationObserver(function () {
            if (speech.textContent.trim()) openTutor();
        }).observe(speech, { childList: true, characterData: true, subtree: true });
    }
    if (box) box.addEventListener('click', closeTutor);
    if (recall) recall.addEventListener('click', openTutor);
    phone.addEventListener('change', closeTutor);
})();
