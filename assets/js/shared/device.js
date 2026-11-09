function getDeviceSignature() {
    const ua = navigator.userAgent;
    let platform = 'Unknown Device';
    if (/android/i.test(ua)) platform = 'Android Smartphone';
    else if (/iPad/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1))
        platform = 'iPadOS Tablet';
    else if (/iPhone|iPod/.test(ua)) platform = 'iOS Device';
    else if (/Macintosh|MacIntel|MacPPC|Mac68K/.test(ua)) platform = 'macOS Computer';
    else if (/Windows/.test(ua)) platform = 'Windows PC';

    const uniqueId = Math.random().toString(36).substring(2, 9);
    return `${uniqueId} [${platform}]`;
}

function getOrCreateDeviceId() {
    let deviceId = localStorage.getItem('pia_device_id');
    if (!deviceId || !deviceId.includes('[')) {
        deviceId = getDeviceSignature();
        localStorage.setItem('pia_device_id', deviceId);
    }
    return deviceId;
}

async function enforceDeviceLimit(email, profile) {
    if (!window.supabaseClient) return { allowed: false, reason: 'No connection to the server.' };

    const { data, error } = await supabaseClient.rpc('claim_device', {
        p_device_id: getOrCreateDeviceId()
    });

    if (error) {
        return { allowed: false, reason: error.message || 'Could not check the device limit.' };
    }
    if (!data || data.allowed !== true) {
        return { allowed: false, reason: (data && data.reason) || 'Device limit reached.' };
    }
    return { allowed: true };
}

async function claimStudentSession() {
    if (!window.supabaseClient) return { allowed: false, reason: 'No connection to the server.' };

    const { error } = await supabaseClient.rpc('claim_student_session', {
        p_device_id: getOrCreateDeviceId()
    });

    if (error) {
        if (isMissingFunction(error)) return { allowed: false, missing: true };
        return {
            allowed: false,
            reason: isNetworkFailure(error)
                ? 'Can’t reach the server. Check your Wi-Fi, then try again.'
                : 'We couldn’t start your session. Please try again.'
        };
    }
    return { allowed: true };
}
