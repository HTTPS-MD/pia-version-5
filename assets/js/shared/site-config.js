/*
 * Site setup.
 * Supabase address and key, the sign-in storage, the shared client (window.sb), and email link helpers.
 */
const supabaseUrl = 'https://hvfqqdtemayhhfavmfbs.supabase.co';

const supabaseKey = 'sb_publishable_NXpgU16p8YZ4oedc7MY5ng_J3F-2Mgy';

const PUBLIC_SITE_URL = 'https://personal-instructing-agent-version-1.pages.dev/';

function emailLinkTo(path) {
    return new URL(path, PUBLIC_SITE_URL).href;
}

window.PIA_ENTRY_URL = window.location.href;

window.supabaseClient = null;

window.sb = null;

function isStudentTab() {
    try {
        return sessionStorage.getItem('pia_student_tab') === '1';
    } catch (e) {
        return false;
    }
}

const piaAuthStorage = {
    getItem(key) {
        try {
            return (isStudentTab() ? sessionStorage : localStorage).getItem(key);
        } catch (e) {
            return null;
        }
    },
    setItem(key, value) {
        try {
            (isStudentTab() ? sessionStorage : localStorage).setItem(key, value);
        } catch (e) {}
    },
    removeItem(key) {
        try {
            sessionStorage.removeItem(key);
            localStorage.removeItem(key);
        } catch (e) {}
    }
};

if (window.supabase) {
    window.supabaseClient = window.supabase.createClient(supabaseUrl, supabaseKey, {
        auth: { detectSessionInUrl: !window.PIA_AUTH_FORWARDING, storage: piaAuthStorage }
    });
    window.sb = window.supabaseClient;
    window.SUPABASE_URL = supabaseUrl;
    window.SUPABASE_ANON_KEY = supabaseKey;
}
