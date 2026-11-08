import { handleJoin } from '../../supabase/functions/join-with-number/handler.js';
let t = 1_000_000_000_000;
const rows = [];
const students = {};               // number -> {email, state}
for (let i = 0; i < 40; i++) students['2023123' + String(1000 + i)] = { email: `s${i}@x.test`, state: 'present' };
const deps = {
  now: () => t,
  countFailures: async (k, s) => rows.filter(r => r.key === k && !r.ok && r.at >= s).length,
  countSuccesses: async (k, s) => rows.filter(r => r.key === k && r.ok && r.at >= s).length,
  record: async (k, ok) => { rows.push({ key: k, ok, at: t }); },
  anyCheckinOpen: async () => true,
  checkinOpenFor: async () => true,
  findStudent: async (n) => students[n] ? { email: students[n].email, section: 'A', role: 'student', full_name: 'x' } : null,
  experimentEndedFor: async () => false,
  standingFor: async (_s, e) => Object.values(students).find(x => x.email === e).state === 'entered' ? 'entered' : 'present',
  claimEntry: async (_s, e) => { const st = Object.values(students).find(x => x.email === e); if (st.state === 'entered') return false; st.state = 'entered'; return true; },
  releaseEntry: async () => {}, noteReentry: async () => {}, ensureAccount: async () => {}, mintToken: async () => 'tok'
};
const nums = Object.keys(students);
const LAB = '10.0.0.1';
const check = (name, cond) => { console.log((cond ? 'PASS ' : 'FAIL ') + name); if (!cond) process.exitCode = 1; };
// 1. First 5 lab students enter.
for (let i = 0; i < 5; i++) { const r = await handleJoin({ action: 'enter', number: nums[i] }, LAB, deps); check('lab student ' + i + ' let in', r.status === 200); }
// 2. Outsider floods 300 bad numbers from rotating addresses.
let blocked = 0;
for (let i = 0; i < 300; i++) { const r = await handleJoin({ action: 'enter', number: String(90000000000 + i) }, 'evil-' + (i % 20), deps); if (r.status === 429) blocked++; }
check('outsider gets throttled after global cap (blocked ' + blocked + ')', blocked >= 90);
// 3. Lab keeps working.
let ok = 0;
for (let i = 5; i < 40; i++) { const r = await handleJoin({ action: 'enter', number: nums[i] }, LAB, deps); if (r.status === 200) ok++; }
check('remaining 35 lab students still let in (' + ok + ')', ok === 35);
// 4. A brand-new address is still blocked while the cap holds.
const fresh = await handleJoin({ action: 'enter', number: '99999999999' }, 'new-addr', deps);
check('new address blocked while cap holds', fresh.status === 429);
// 5. Per-IP cap still applies to the lab.
for (let i = 0; i < 150; i++) await handleJoin({ action: 'enter', number: String(80000000000 + i) }, LAB, deps);
const labAfter = await handleJoin({ action: 'enter', number: '80000000999' }, LAB, deps);
check('lab still limited by its own cap of 150', labAfter.status === 429);
// 6. Old behaviour before cap: unknown number = 403 refusal.
t += 13 * 60 * 60_000;
const later = await handleJoin({ action: 'enter', number: '12345678901' }, 'someone', deps);
check('after the window an unknown number is a normal refusal', later.status === 403);
