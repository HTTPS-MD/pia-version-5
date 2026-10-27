/*
 * Student number box on the first screen.
 */
(function () {
    'use strict';

    var Auth = window.PIAAuth;

    function showJoinError(message) {
        $('#join-error-text').textContent = message;
        Auth.openModal('modal-join-error');
    }

    var heroJoinPending = false;

    async function heroJoin(form) {
        var number = $('.join-in', form).value.replace(/\D/g, '');
        if (heroJoinPending || number.length === 0) {
            return;
        }
        if (typeof sb === 'undefined' || !sb) {
            showJoinError('The sign-in service is unavailable. Check your connection and reload.');
            return;
        }
        if (number.length !== 11) {
            showJoinError('Type your code.');
            return;
        }

        heroJoinPending = true;
        var button = $('.join-btn', form);
        var release = Auth.setBusy(button, 'Wait…');
        var walkedIn = false;
        try {
            var found = await Auth.joinCall({ action: 'lookup', number: number });
            if (!found.ok) {
                showJoinError(
                    (found.data && found.data.error) || 'Could not check the number. Try again.'
                );
                return;
            }
            var entered = await Auth.joinCall({ action: 'enter', number: number });
            if (!entered.ok) {
                showJoinError(
                    (entered.data && entered.data.error) || 'Could not let you in. Try again.'
                );
                return;
            }
            walkedIn = true;
            await Auth.enterWithToken(entered.data.token_hash, {
                current: function () {
                    return true;
                },
                fail: function (message) {
                    walkedIn = false;
                    showJoinError(message);
                },
                report: function () {
                    button.textContent = 'Wait…';
                }
            });
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
