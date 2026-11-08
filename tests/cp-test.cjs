/* Isolated browser verification for Batch 3 (Admin dashboard).
   Every non-loopback request is intercepted and the Supabase SDK is replaced by
   an in-memory fixture that really filters, counts, orders and pages, so the
   console's own queries are exercised. Nothing here contacts Supabase, sends
   email or touches an account. Mocked success is front-end evidence only. */
const { chromium } = require('playwright');
const { createServer } = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const out = process.env.PIA_TEST_OUTPUT || '/tmp/pia-batch-3-evidence';
fs.mkdirSync(out, { recursive: true });
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.png': 'image/png', '.jpg': 'image/jpeg' };
const server = createServer((req, res) => {
  const file = path.resolve(root, '.' + decodeURIComponent(new URL(req.url, 'http://localhost').pathname));
  if (!file.startsWith(root + path.sep)) { res.writeHead(403).end(); return; }
  fs.readFile(file, (error, data) => {
    if (error) { res.writeHead(404).end(); return; }
    res.setHeader('Content-Type', mime[path.extname(file)] || 'application/octet-stream');
    res.end(data);
  });
});

/* ------------------------------------------------------------------ data -- */
function makeData(overrides = {}) {
  const students = [];
  const sections = ['Earth', 'Jupiter', 'Mars', 'Venus'];   /* Venus has no students */
  const groups = ['assigned', 'non-assigned', 'neutral', 'control'];
  for (let i = 1; i <= 23; i++) {
    const n = String(i).padStart(2, '0');
    let stage = 'Waiting Room', game = false;
    if (i <= 5) stage = 'OCEAN';
    else if (i <= 9) stage = 'Character Selection';
    else if (i <= 15) { stage = 'Tutoring Dashboard'; if (i <= 12) game = true; }
    students.push({
      full_name: `Student ${n}`, email: `student${n}@example.test`, role: 'student',
      section: i <= 8 ? 'Earth' : i <= 16 ? 'Jupiter' : (i <= 22 ? 'Mars' : null),
      group_type: groups[i % 4], status: i % 8 === 0 ? 'inactive' : 'active',
      current_stage: stage, is_in_game: game, stage_started_at: null, selected_character: null,
      active_devices: [3, 6, 9, 10, 18].includes(i) ? ['abc [Windows PC]'] : [], max_devices: 1,   /* signed in: 3,6 (connected), 9,10 (stale beat), 18 (never beat: waiting room) */
      is_ocean_done: i > 5, pre_test_score: null, post_test_score: null,
      parental_consent: true, student_assent: true, must_change_password: false
    });
  }
  students[22].full_name = 'Bartholomew-Maximilian-Alexandrovich-Fitzgerald-Montgomery Wolfeschlegelsteinhausen';
  students[22].email = 'a.very.long.email.address.for.wrapping.checks.bartholomew.maximilian@subdomain.example.test';
  const admins = [
    { full_name: 'Ada Admin', email: 'admin@example.test', role: 'admin', status: 'active', active_devices: ['dev-self [macOS Computer]'], max_devices: 99 },
    { full_name: 'Ben Other', email: 'ben@example.test', role: 'admin', status: 'inactive', active_devices: [], max_devices: 99 },
    { full_name: 'Cy Signed', email: 'cy@example.test', role: 'admin', status: 'active', active_devices: ['x [Windows PC]'], max_devices: 99 }
  ];
  const professors = [
    { name: 'Prof One', email: 'prof1@example.test', department: 'Mathematics', assigned_section: 'Earth', status: 'active' },
    { name: 'Prof Two', email: 'prof2@example.test', department: 'Science', assigned_section: null, status: 'inactive' }
  ];
  /* beatAgo = seconds since the stage page last checked in. */
  const stageTimes = {};
  for (let i = 1; i <= 8; i++) {
    const e = `student${String(i).padStart(2, '0')}@example.test`;
    stageTimes[e] = { student_email: e, ocean_time: 65 * i, character_select_time: 0, tutoring_time: 0, heartbeat_stage: 'OCEAN', beatAgo: 5 };
  }
  for (let i = 9; i <= 12; i++) {
    const e = `student${String(i).padStart(2, '0')}@example.test`;
    stageTimes[e] = { student_email: e, ocean_time: 0, character_select_time: 0, tutoring_time: 3725 + i, heartbeat_stage: 'Tutoring Dashboard', beatAgo: 600 };
  }
  return Object.assign({
    profiles: students.concat(admins), sections: sections.map(name => ({ name })), professors,
    settings: [{ key: 'stage_ocean', value: false }, { key: 'stage_char', value: false }, { key: 'stage_dash', value: false }],
    stage_overrides: [], tutoring_schedule: [], ocean_submissions: [], question_bank: [], app_config: [],
    student_stage_time: stageTimes
  }, overrides);
}

/* ---------------------------------------------------- in-page Supabase -- */
function fixture() {
  const f = window.fixture = Object.assign({ calls: [], data: null, fail: {}, delay: {}, signoutError: false, resetError: null, resetDelay: 0, passwordCheck: 'ok', searchDelay: [] }, window.fixtureInitial || {});
  const me = 'admin@example.test';
  const tbl = n => f.data[n] || [];
  const rowsFor = name => {
    if (name === 'student_stage_time') {
      return Object.values(f.data.student_stage_time || {}).map(r => Object.assign({}, r, {
        last_heartbeat_timestamp: new Date(Date.now() - r.beatAgo * 1000).toISOString() }));
    }
    return tbl(name).map(r => Object.assign({}, r));
  };
  const parseOr = expr => expr.split(',').map(part => { const m = part.match(/^([a-z_]+)\.ilike\.%(.*)%$/); return m ? { col: m[1], term: m[2].toLowerCase() } : null; }).filter(Boolean);

  function builder(name) {
    const b = { filters: [], order: null, range: null, limit: null, count: null, head: false, single: false, signal: null, write: null };
    const api = {
      select(cols, opts) { b.cols = cols; if (opts && opts.count) b.count = opts.count; if (opts && opts.head) b.head = true; return api; },
      eq(c, v) { b.filters.push(r => r[c] === v); return api; },
      neq(c, v) { b.filters.push(r => r[c] !== v); return api; },
      not(c, op, v) { if (op === 'in') { const list = Array.isArray(v) ? v : String(v).replace(/[()"']/g, '').split(',').map(s => s.trim()); b.filters.push(r => list.indexOf(r[c]) === -1); } else if (op === 'is') { b.filters.push(r => (v === null ? r[c] != null : r[c] !== v)); } else { b.filters.push(r => r[c] !== v); } return api; },
      in(c, vs) { b.filters.push(r => vs.indexOf(r[c]) !== -1); return api; },
      or(expr) { const conds = parseOr(expr); b.filters.push(r => conds.some(x => String(r[x.col] || '').toLowerCase().indexOf(x.term) !== -1)); return api; },
      order(c, o) { b.order = { c, asc: !o || o.ascending !== false }; return api; },
      range(a, z) { b.range = [a, z]; return api; },
      limit(n) { b.limit = n; return api; },
      abortSignal(s) { b.signal = s; return api; },
      maybeSingle() { b.single = true; return api; },
      single() { b.single = true; return api; },
      insert(v) { b.write = { op: 'insert', v }; return api; },
      update(v) { b.write = { op: 'update', v }; return api; },
      delete() { b.write = { op: 'delete' }; return api; },
      upsert(v) { b.write = { op: 'upsert', v }; return api; },
      then(resolve, reject) { return run().then(resolve, reject); }
    };
    async function run() {
      f.calls.push({ method: 'from', table: name, write: b.write && b.write.op, cols: b.cols, values: b.write && b.write.v, filters: b.filters.length });
      const wait = f.delay[name] || 0;
      if (wait) await new Promise(r => setTimeout(r, wait));
      if (b.signal && b.signal.aborted) { const e = new Error('aborted'); e.name = 'AbortError'; throw e; }
      if (b.write && f.failWrite && f.failWrite[name]) return { data: null, error: Object.assign({ message: 'fixture write failure' }, f.failWrite[name]), count: null };
      if (f.fail[name]) return { data: null, error: Object.assign({ message: 'fixture failure' }, f.fail[name]), count: null };
      if (b.write) return { data: null, error: null };
      let rows = rowsFor(name).filter(r => b.filters.every(fn => fn(r)));
      if (b.order) rows.sort((x, y) => String(x[b.order.c] == null ? '' : x[b.order.c]).localeCompare(String(y[b.order.c] == null ? '' : y[b.order.c])) * (b.order.asc ? 1 : -1));
      const total = rows.length;
      if (b.range) rows = rows.slice(b.range[0], b.range[1] + 1);
      if (b.limit != null) rows = rows.slice(0, b.limit);
      if (b.single) return { data: rows[0] || null, error: null };
      return { data: b.head ? null : rows, error: null, count: b.count ? total : null };
    }
    return api;
  }

  const user = { id: 'isolated-admin', email: me };
  const auth = {
    getSession: async () => ({ data: { session: { access_token: 'isolated', user } }, error: null }),
    getUser: async () => ({ data: { user }, error: null }),
    onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
    signOut: async (args) => {
      f.calls.push({ method: 'signOut', args });
      if (f.signoutError && (!args || args.scope === 'global')) return { error: { message: 'Network request failed' } };
      return { error: null };
    },
    resetPasswordForEmail: async (email, opts) => {
      f.calls.push({ method: 'reset', email, redirectTo: opts && opts.redirectTo });
      if (f.resetDelay) await new Promise(r => setTimeout(r, f.resetDelay));
      return { data: {}, error: f.resetError };
    },
    signInWithPassword: async (args) => {
      f.calls.push({ method: 'probeSignIn' });
      if (args.password === 'wrong-password') return { data: null, error: { status: 400, message: 'Invalid login credentials' } };
      return { data: { user }, error: null };
    },
    updateUser: async (args) => { f.calls.push({ method: 'updateUser', keys: Object.keys(args || {}) }); return { data: { user }, error: null }; },
    signInWithOtp: async () => ({ data: {}, error: null })
  };
  const api = {
    auth,
    from: name => builder(name),
    rpc: async (name, args) => {
      f.calls.push({ method: 'rpc', name, args });
      if (name === 'jwt_is_current') return { data: true, error: null };
      if (name === 'pia_admin_tutorial_report') {
        if (f.fail[name]) return { data: null, error: f.fail[name] };
        return { data: (f.data.tutorial_reports || {})[args.p_student_email] || {
          summary: { sessions: 0, completed_questions: 0, clean_questions: 0,
            best_topic: null, avg_speed_seconds: null, accuracy_percent: null,
            score_sum: 0, errors: 0, hints: 0 }, history_total: 0, history: []
        }, error: null };
      }
      if (name === 'admin_create_auth_user') {
        if ((f.authFail || []).indexOf(args.target_email) !== -1) return { data: null, error: { message: 'fixture auth failure' } };
        return { data: { ok: true }, error: null };
      }
      if (name === 'admin_grant_stage') {
        (f.data.stage_overrides = f.data.stage_overrides || []).push({ stage: args.p_stage, section: args.p_section, granted_count: 1 });
        return { data: { granted: ['student01@example.test'], skipped: [] }, error: null };
      }
      if (name === 'admin_revoke_stage') {
        f.data.stage_overrides = (f.data.stage_overrides || []).filter(o => !(o.stage === args.p_stage && args.p_sections.indexOf(o.section) !== -1));
        return { data: { moved: 0 }, error: null };
      }
      if (name === 'admin_set_tutoring_schedule') {
        f.data.tutoring_schedule = (f.data.tutoring_schedule || []).filter(r => r.section !== args.p_section);
        if (args.p_opens || args.p_closes) f.data.tutoring_schedule.push({ section: args.p_section, opens_at: args.p_opens, closes_at: args.p_closes });
        return { data: { section: args.p_section }, error: null };
      }
      if (name === 'claim_device') {
        const mine = args.p_device_id;
        const row = f.data.profiles.find(p => p.email === me);
        if (row.active_devices.indexOf(mine) === -1) row.active_devices = [mine, 'other-dev [Windows PC]'];
        return { data: { allowed: true, devices: row.active_devices }, error: null };
      }
      return { data: { ok: true }, error: null };
    },
    /* Keeps the realtime callbacks so a test can deliver another admin's save (window.__emitRealtime). */
    channel: (name) => { const ch = { on(type, filter, cb) { (window.__rt = window.__rt || []).push({ name, filter, cb }); return ch; }, subscribe() { return ch; } }; return ch; },
    removeChannel() {}
  };
  window.supabase = { createClient: () => api };
}

(async () => {
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ headless: true, executablePath: process.env.PIA_CHROME, args: ['--disable-background-networking'] });
  const results = [];
  const leaked = [];
  const ADMIN = '/admin/html/admin-dashboard.html';

  async function open(route = 'overview', { width = 1280, height = 900, theme = 'dark', initial = {}, data, reduced = false, clock = false } = {}) {
    const context = await browser.newContext({ viewport: { width, height }, serviceWorkers: 'block', reducedMotion: reduced ? 'reduce' : 'no-preference' });
    await context.addInitScript(i => window.fixtureInitial = i, Object.assign({ data: data || makeData() }, initial));
    await context.addInitScript(t => { try { if (!localStorage.getItem('pia_theme')) localStorage.setItem('pia_theme', t); localStorage.setItem('pia_user_email', 'admin@example.test'); } catch (e) {} }, theme);
    await context.route('**/*', r => {
      const u = r.request().url();
      if (u.includes('/assets/js/vendor/supabase.js')) return r.fulfill({ contentType: 'text/javascript', body: `(${fixture.toString()})();` });
      if (u.startsWith(origin + '/')) return r.continue();
      leaked.push(u); return r.abort('blockedbyclient');
    });
    const page = await context.newPage();
    page.setDefaultTimeout(8000);
    page.on('pageerror', e => results.push({ error: e.message, stack: String(e.stack).split('\n').slice(0, 3).join(' | ') }));
    if (clock) await page.clock.install({ time: new Date() });
    await page.goto(origin + ADMIN + '#' + route);
    await page.waitForFunction(() => !document.body.hasAttribute('data-boot'));
    return page;
  }
  const page = await open('settings', { theme: 'dark', reduced: true }); await page.waitForTimeout(1200);
  const out = [];
  const state = async label => { await page.waitForTimeout(400); out.push({ label, msgs: await page.evaluate(() => [...document.querySelectorAll('#modal-change-password .field-msg')].map(e => e.textContent.trim()).join(' | '), ) , errors: results.filter(r => r.error && !/Stage counters/.test(r.error)).map(r => r.error).slice(-2) }); };
  await page.evaluate(() => document.querySelector('[data-modal-open="modal-change-password"]').click()); await page.waitForTimeout(400);
  const set = async (id, v) => page.evaluate(([i, x]) => { const e = document.getElementById(i); if (e) { e.value = x; e.dispatchEvent(new Event('input', { bubbles: true })); } }, [id, v]);
  await set('cp-current', 'OldPass123'); await set('cp-new', 'short'); await set('cp-confirm', 'short');
  await page.evaluate(() => document.querySelector('#change-password-form').requestSubmit()); await state('too short');
  await set('cp-new', 'OldPass123'); await set('cp-confirm', 'OldPass123'); await page.evaluate(() => document.querySelector('#change-password-form').requestSubmit()); await state('same as current');
  await set('cp-new', 'onlyletters'); await set('cp-confirm', 'onlyletters'); await page.evaluate(() => document.querySelector('#change-password-form').requestSubmit()); await state('no digit');
  console.log(JSON.stringify(out, null, 1)); await browser.close(); server.close();
})();
