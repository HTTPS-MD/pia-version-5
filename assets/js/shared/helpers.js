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

function piaDialog(opts) {
    const o = opts || {};
    const root = document.createElement('div');
    if (o.id) root.id = o.id;
    root.className = 'overlay is-mounted';
    root.setAttribute('role', o.role || 'dialog');
    root.setAttribute('aria-modal', 'true');
    if (o.zIndex) root.style.zIndex = o.zIndex;

    const modal = document.createElement('div');
    modal.className = 'modal modal-sm';

    const head = document.createElement('header');
    head.className = 'modal-head';
    const headText = document.createElement('div');
    headText.className = 'modal-head-text';

    if (o.icon) {
        const glyph = document.createElement('span');
        glyph.className = 'modal-glyph';
        glyph.setAttribute('aria-hidden', 'true');
        glyph.innerHTML = o.icon;
        headText.append(glyph);
    }

    const title = document.createElement('h2');
    title.className = 'modal-title';
    title.id = (o.id || 'pia-dialog') + '-title';
    title.textContent = o.title || '';
    root.setAttribute('aria-labelledby', title.id);
    headText.append(title);

    const sub = document.createElement('p');
    sub.className = 'modal-sub';
    sub.id = (o.id || 'pia-dialog') + '-text';
    if (o.textHtml) sub.innerHTML = o.textHtml;
    else sub.textContent = o.text || '';
    root.setAttribute('aria-describedby', sub.id);
    headText.append(sub);
    head.append(headText);
    modal.append(head);

    if (o.note) {
        const body = document.createElement('div');
        body.className = 'modal-body';
        const note = document.createElement('p');
        note.className = 'modal-text';
        note.textContent = o.note;
        body.append(note);
        modal.append(body);
    }

    const buttons = {};
    const foot = document.createElement('footer');
    foot.className = 'modal-foot';
    (o.actions || []).forEach((a) => {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'btn ' + (a.primary ? 'btn-primary' : 'btn-secondary');
        btn.textContent = a.label;
        if (a.id) {
            btn.id = a.id;
            buttons[a.id] = btn;
        }
        if (a.onClick) btn.addEventListener('click', () => a.onClick(btn));
        foot.append(btn);
    });
    modal.append(foot);

    root.append(modal);
    document.body.append(root);

    let opened = false;
    const open = () => {
        if (opened) return;
        opened = true;
        root.classList.add('is-open');
        const first = foot.querySelector('.btn-primary') || foot.querySelector('.btn');
        if (first) first.focus({ preventScroll: true });
    };
    requestAnimationFrame(open);
    setTimeout(open, 100);

    return {
        root,
        close: () => root.remove(),
        button: (id) => buttons[id]
    };
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
