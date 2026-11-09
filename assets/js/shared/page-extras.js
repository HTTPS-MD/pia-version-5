document.addEventListener(
    'error',
    (e) => {
        const el = e.target;
        if (!el || el.tagName !== 'IMG' || el.dataset.fallbackApplied) return;
        el.dataset.fallbackApplied = '1';

        if (/char-|agent-character/.test(el.getAttribute('src') || '')) {
            el.src = '/assets/images/cast/char-1.webp';
        } else {
            el.classList.add('img-missing');
        }
    },
    true
);

const activeChannels = new Map();

function registerChannel(name, buildFn) {
    if (!window.supabaseClient) return null;

    if (activeChannels.has(name)) {
        supabaseClient.removeChannel(activeChannels.get(name));
        activeChannels.delete(name);
    }

    const channel = buildFn(supabaseClient.channel(name));
    activeChannels.set(name, channel);
    return channel;
}

function removeAllChannels() {
    if (!window.supabaseClient) return;
    activeChannels.forEach((channel) => supabaseClient.removeChannel(channel));
    activeChannels.clear();
}

window.addEventListener('pagehide', removeAllChannels);
