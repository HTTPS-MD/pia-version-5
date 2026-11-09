(function () {
    'use strict';

    var hash = new URLSearchParams(window.location.hash.replace(/^#/, ''));
    var query = new URLSearchParams(window.location.search);

    var isAuthResult =
        hash.has('access_token') ||
        hash.has('error_description') ||
        query.has('token_hash') ||
        query.has('error_description');

    if (!isAuthResult) {
        return;
    }

    if (query.get('flow') === 'device-reset' || query.get('flow') === 'set-password') {
        return;
    }

    window.PIA_AUTH_FORWARDING = true;

    document.documentElement.style.visibility = 'hidden';

    window.location.replace(
        'assets/html/sign-up.html' + window.location.search + window.location.hash
    );
})();
