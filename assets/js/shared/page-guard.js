(function () {
    'use strict';

    function enforceAuthGuard() {
        var email = null;
        try {
            email = localStorage.getItem('pia_user_email');
        } catch (e) {}
        if (!email) {
            var staff = /\/(admin|teacher)\//.test(window.location.pathname);
            window.location.replace(staff ? '../../index.html?signin=staff' : '../../index.html');
        }
    }

    enforceAuthGuard();

    window.addEventListener('pageshow', function (event) {
        if (event.persisted) {
            enforceAuthGuard();
        }
    });
})();
