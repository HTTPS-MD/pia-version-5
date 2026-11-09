(function () {
    'use strict';

    var Auth = window.PIAAuth;

    function showJoinError(message) {
        Auth.showJoinError(message);
    }

    var heroJoinPending = false;

    async function heroJoin(form) {
        var typed = $('.join-in', form).value.trim();
        var number = typed.replace(/\D/g, '');
        if (heroJoinPending || typed.length === 0) {
            return;
        }
        if (typeof sb === 'undefined' || !sb) {
            showJoinError('The sign-in service is unavailable. Check your connection and reload.');
            return;
        }
        if (number.length !== 11) {
            showJoinError('Can’t let you in yet. Tell your admin.');
            return;
        }

        heroJoinPending = true;
        var button = $('.join-btn', form);
        var release = Auth.setBusy(button, 'Wait…');
        var walkedIn = false;
        try {
            walkedIn = true;
            var inside = await Auth.joinWithNumber(number, {
                current: function () {
                    return true;
                },
                working: function () {
                    Auth.setBusy(button, 'Wait…');
                },
                fail: function (message) {
                    walkedIn = false;
                    showJoinError(message);
                },
                report: function () {
                    button.textContent = 'Wait…';
                }
            });
            if (!inside) {
                walkedIn = false;
            }
        } catch (err) {
            walkedIn = false;
            showJoinError('Can’t reach the server. Check your Wi-Fi, then try again.');
        } finally {
            heroJoinPending = false;

            if (!walkedIn) {
                release();
            }
        }
    }

    function wireHeroJoin() {
        $$('form.join').forEach(function (form) {
            form.addEventListener('submit', function (event) {
                event.preventDefault();
                heroJoin(form);
            });
        });
    }
    Auth.wireHeroJoin = wireHeroJoin;
})();
