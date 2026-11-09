function showRevokeModal(title, message) {
    if (document.getElementById('global-revoke-modal')) return;

    const modalHTML = `
        <div id="global-revoke-modal" class="revoke-modal-overlay">
            <div class="solid-card revoke-modal-box">
                <div class="revoke-modal-icon-wrap">
                    <i data-lucide="shield-alert" class="icon-lg text-danger"></i>
                </div>
                <h3 class="revoke-modal-title">${title}</h3>
                <p class="text-secondary revoke-modal-desc">${message}</p>
                <div class="revoke-modal-actions">
                    <button id="revoke-modal-btn" class="btn btn-primary btn-lg btn-block">
                        <span>Understood</span>
                    </button>
                </div>
            </div>
        </div>
    `;

    document.body.insertAdjacentHTML('beforeend', modalHTML);
    if (typeof lucide !== 'undefined') lucide.createIcons();

    const modal = document.getElementById('global-revoke-modal');
    const modalBox = modal.querySelector('.solid-card');
    const btn = document.getElementById('revoke-modal-btn');

    requestAnimationFrame(() => {
        modal.classList.add('revoke-modal-visible');
        modalBox.classList.add('revoke-modal-box-visible');
    });

    btn.addEventListener('click', async () => {
        btn.innerHTML = '<i data-lucide="loader-2" class="icon-sm spin"></i> Logging out...';
        if (typeof lucide !== 'undefined') lucide.createIcons();
        btn.disabled = true;
        await executeForceLogout();
    });
}

async function validateDeviceOnLoad() {
    const userEmail = localStorage.getItem('pia_user_email');
    const currentDeviceId = localStorage.getItem('pia_device_id');

    if (
        !userEmail ||
        !currentDeviceId ||
        window.location.pathname.includes('admin-dashboard') ||
        window.location.pathname.includes('sign-in.html') ||
        window.location.pathname.includes('sign-up.html')
    ) {
        return;
    }

    if (window.supabaseClient) {
        const { data } = await window.supabaseClient
            .from('profiles')
            .select('active_devices')
            .eq('email', userEmail)
            .maybeSingle();

        if (data && data.active_devices) {
            if (!data.active_devices.includes(currentDeviceId)) {
                deviceDropped('Your device session was revoked by the administrator.');
            }
        }
    }
}

async function deviceDropped(adminMessage) {
    if (piaSessionEnded) return;
    const status =
        localStorage.getItem('pia_user_role') === 'student' ? await fetchSessionStatus() : null;
    if (status === 'replaced') {
        endStudentSession('replaced');
        return;
    }
    showRevokeModal('Session Revoked', adminMessage);
}

async function watchDeviceSession() {
    const userEmail = localStorage.getItem('pia_user_email');
    const currentDeviceId = localStorage.getItem('pia_device_id');

    if (!userEmail || !currentDeviceId) return;
    if (
        window.location.pathname.includes('admin-dashboard') ||
        window.location.pathname.includes('sign-in.html') ||
        window.location.pathname.includes('sign-up.html')
    )
        return;

    registerChannel('global-device-revocation-' + userEmail, (ch) =>
        ch
            .on(
                'postgres_changes',
                {
                    event: '*',
                    schema: 'public',
                    table: 'profiles',
                    filter: `email=eq.${userEmail}`
                },
                async (payload) => {
                    if (payload.eventType === 'DELETE') {
                        showRevokeModal(
                            'Account Deleted',
                            'Your account has been permanently removed.'
                        );
                        return;
                    }

                    const updatedProfile = payload.new;
                    if (!updatedProfile) return;

                    const activeDevices = updatedProfile.active_devices || [];
                    if (!activeDevices.includes(currentDeviceId)) {
                        if (sessionStorage.getItem('is_signing_out') === 'true') return;
                        deviceDropped('Your device session was disconnected by the administrator.');
                    }
                }
            )
            .subscribe()
    );
}

async function executeForceLogout() {

    if (piaSessionEnded) {
        clearLocalSession();
        window.location.replace('/index.html');
        return;
    }
    piaUserSigningOut = true;

    sessionStorage.setItem('is_signing_out', 'true');

    const deviceId = localStorage.getItem('pia_device_id');

    try {
        if (window.supabaseClient) {
            clearInterval(presenceTimerId);
            await window.supabaseClient.rpc('touch_presence', { p_online: false });
            if (deviceId) {
                await window.supabaseClient.rpc('release_device', { p_device_id: deviceId });
            }
            await window.supabaseClient.auth.signOut({ scope: 'global' });
        }
    } catch (e) {
        console.error('Sign-out cleanup failed:', e);
    }

    localStorage.clear();
    sessionStorage.clear();
    if (deviceId) localStorage.setItem('pia_device_id', deviceId);

    window.location.replace('/index.html');
}
