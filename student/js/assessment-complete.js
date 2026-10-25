(async function () {
    const profile = await requireStudentSession();
    if (!profile) return;

    if (!profile.is_ocean_done) {
        window.location.replace('ocean-test.html');
        return;
    }

    const continueBtn = document.getElementById('btn-continue');
    if (isControlGroup(profile)) {
        const actions = continueBtn && continueBtn.closest('.gate-actions');
        if (actions) actions.remove();
        const lede = document.querySelector('.gate-lede');
        if (lede) lede.textContent = 'Your answers have been saved. That is everything for now.';
    } else if (continueBtn) {
        continueBtn.href = await resolveStudentRedirect(profile);
    }

    document.body.classList.remove('opacity-0');
})();
