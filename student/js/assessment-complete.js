(async function () {
    const profile = await requireStudentSession();
    if (!profile) return;

    if (!profile.is_ocean_done) {
        window.location.replace('ocean-test.html');
        return;
    }
    if (isControlGroup(profile)) {
        window.location.replace('thank-you.html');
        return;
    }

    const continueBtn = document.getElementById('btn-continue');
    if (continueBtn) continueBtn.href = await resolveStudentRedirect(profile);

    document.body.classList.remove('opacity-0');
})();
