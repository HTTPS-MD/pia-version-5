(async function () {
    const profile = await requireStudentSession();
    if (!profile) return;

    if (!profile.is_ocean_done) {
        window.location.replace('ocean-test.html');
        return;
    }
    if (!isControlGroup(profile)) {
        window.location.replace(await resolveStudentRedirect(profile));
        return;
    }

    document.body.classList.remove('opacity-0');
})();
