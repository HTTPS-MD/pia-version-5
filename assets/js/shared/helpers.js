/*
 * Small shared helpers.
 * escapeHTML, $ and $$, safeInt, and checks for network errors.
 */
function escapeHTML(str) {
    if (str === null || str === undefined) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}

function $(selector, root) {
    return (root || document).querySelector(selector);
}

function $$(selector, root) {
    return Array.prototype.slice.call((root || document).querySelectorAll(selector));
}

function safeInt(value, fallback = 0) {
    const n = parseInt(value, 10);
    return Number.isFinite(n) ? n : fallback;
}

function isMissingFunction(error) {
    return !!error && (error.code === 'PGRST202' || error.code === '42883');
}

function isNetworkFailure(error) {
    if (navigator.onLine === false) return true;
    if (!error || error.code || error.status) return false;
    return /fetch|network|load failed|timeout|offline/i.test(String(error.message || ''));
}

const OCEAN_SCORE_MAX = 40;
