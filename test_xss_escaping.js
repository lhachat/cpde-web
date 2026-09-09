#!/usr/bin/env node
/*
test_xss_escaping.js -- stored XSS regression: server-echoed strings must
render as inert text everywhere the UI displays them, and the CSP must
block inline script even if an escaping site is ever missed.

Confirmed real by the security audit (2026-09-09): PursuitPatch.name had
no content restriction, index.html had no HTML-escaping helper at all,
and server data was interpolated straight into innerHTML. Proven live
with `<i data-audit-probe=1>probe</i>` on pursuit 1060's name, returned
raw by /api/bootstrap.

This test plants that EXACT audit payload (plus an execution attempt,
<img onerror>) on a real pursuit's name via the real PATCH endpoint,
drives the real UI through every view that displays a pursuit name,
and asserts:
  1. no element the payload describes ever exists in the DOM
     ([data-audit-probe], img[src=x]) -- in the Pursuits list, the
     detail title, another pursuit's Depends-on picker, the Sandbox
     table and questionnaire header, the B&P tables, the Dashboard;
  2. the payload is visible as LITERAL text where the name is shown;
  3. window.__xss was never set (the onerror never ran);
  4. the search box reflects a typed payload inertly (FLT.q);
  5. a Content-Security-Policy header is present on the app page with a
     per-response nonce and NO 'unsafe-inline' for scripts;
  6. CSP actually BLOCKS an inline script and an inline event-handler
     attribute injected into the live page (a securitypolicyviolation
     event fires and neither executes) -- tested directly, not just by
     header presence.

The pursuit's name is restored via the real PATCH endpoint in a finally
block, so a mid-run failure never leaves the payload behind.

    node test_xss_escaping.js --base http://localhost:8001

Requires the API running and `npm install` (playwright is a
devDependency). Exit 0 = all passed.
*/
const { chromium, request } = require('playwright');

const args = process.argv.slice(2);
const BASE = (args.includes('--base') ? args[args.indexOf('--base') + 1] : null)
  || 'http://localhost:8001';
const EMAIL = 'aero.admin@demoaero.test';
const FIXTURE_OPP = '1060';        // real AERO Best Value pursuit, open
const DEPENDENT_OPP = '1073';      // real dependent pursuit whose Depends-on picker is editable
const PROBE = '<i data-audit-probe=1>probe</i>';                 // the audit's exact payload
const EXEC = '<img src=x onerror="window.__xss=1">';            // plus an execution attempt

const PASS = [], FAIL = [];
function check(name, ok, detail) {
  (ok ? PASS : FAIL).push(name);
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${!ok && detail ? '  -- ' + detail : ''}`);
}

// detailView() re-renders itself once loadReference() resolves on the
// first open of a session (REF-driven dropdowns). Clicking Back before
// that lands gets undone by the deferred re-render -- a human never
// wins that race, an automated click does. Wait for the REF-driven
// market options to be present before interacting with detail.
async function waitForDetailSettled(page) {
  await page.waitForSelector('.dtt', { timeout: 10000 });
  await page.waitForFunction(
    () => document.querySelectorAll('[data-ed="market"] option').length > 1, null, { timeout: 15000 });
  await page.waitForTimeout(200);
}

async function domProbe(page, where) {
  const r = await page.evaluate(() => ({
    probe: document.querySelectorAll('[data-audit-probe]').length,
    img: document.querySelectorAll('img[src="x"]').length,
    xss: window.__xss,
    text: document.body.innerText,
  }));
  check(`${where}: no element from the payload exists in the DOM`,
        r.probe === 0 && r.img === 0, `probe=${r.probe} img=${r.img}`);
  check(`${where}: the onerror payload never executed`, r.xss === undefined, `window.__xss=${r.xss}`);
  return r;
}

(async () => {
  const api = await request.newContext({ baseURL: BASE });
  const login = await api.post('/api/login', { data: { email: EMAIL } });
  if (!login.ok()) { console.error('login failed', login.status()); process.exit(1); }
  const boot = await (await api.get('/api/bootstrap')).json();
  const fixture = boot.pursuits.find(p => String(p.opp_id) === FIXTURE_OPP);
  const dependent = boot.pursuits.find(p => String(p.opp_id) === DEPENDENT_OPP);
  if (!fixture || !dependent) { console.error('fixtures missing'); process.exit(1); }
  const origName = fixture.name;
  const payloadName = `${origName} ${PROBE}${EXEC}`;

  let browser;
  try {
    const patched = await api.patch(`/api/pursuits/${fixture.id}`, { data: { name: payloadName } });
    check('PATCH stores the payload name (server keeps raw text; escaping is an output concern)',
          patched.ok(), `got ${patched.status()}`);

    browser = await chromium.launch();
    const page = await browser.newPage();
    await page.addInitScript(() => {
      window.__cspv = [];
      document.addEventListener('securitypolicyviolation',
        e => window.__cspv.push(`${e.violatedDirective}:${e.blockedURI || 'inline'}`));
    });

    const resp = await page.goto(BASE + '/', { waitUntil: 'networkidle' });
    const csp = resp.headers()['content-security-policy'] || '';
    check('Content-Security-Policy header is present on the app page', !!csp, 'no header');
    check("script-src carries a per-response nonce and no 'unsafe-inline'",
          /script-src[^;]*'nonce-[A-Za-z0-9_-]{16,}'/.test(csp) && !/script-src[^;]*'unsafe-inline'/.test(csp), csp);
    check("object-src 'none' and frame-ancestors 'none' are set",
          /object-src 'none'/.test(csp) && /frame-ancestors 'none'/.test(csp), csp);
    const resp2 = await page.goto(BASE + '/', { waitUntil: 'networkidle' });
    const nonce1 = (csp.match(/'nonce-([^']+)'/) || [])[1];
    const nonce2 = ((resp2.headers()['content-security-policy'] || '').match(/'nonce-([^']+)'/) || [])[1];
    check('the nonce differs per response (not a fixed string)', nonce1 && nonce2 && nonce1 !== nonce2);

    await page.fill('#loginEmail', EMAIL);
    await page.click('#loginGo');
    await page.waitForSelector('#dash .kpis', { timeout: 15000 });
    check('the app itself still runs under the CSP (its own script executed)',
          await page.evaluate(() => typeof window.goToPursuits === 'function'));

    console.log('\n=== Dashboard ===');
    await domProbe(page, 'Dashboard');

    console.log('\n=== Pursuits list ===');
    await page.click('#nav a[data-v="pursuits"]');
    await page.fill('#fq', origName);
    await page.waitForTimeout(300);
    const r1 = await domProbe(page, 'Pursuits list');
    check('Pursuits list shows the payload as literal text', r1.text.includes(PROBE), 'literal text not found');

    console.log('\n=== search box reflection ===');
    await page.fill('#fq', '"><i data-q-probe=1>x');
    await page.waitForTimeout(300);
    check('a payload typed into the search box is reflected inertly',
          await page.evaluate(() => document.querySelectorAll('[data-q-probe]').length === 0
                                    && document.getElementById('fq').value === '"><i data-q-probe=1>x'));
    await page.fill('#fq', origName);
    await page.waitForTimeout(300);

    console.log('\n=== Pursuit detail ===');
    await page.click(`#pursuits tbody tr[data-uid="${FIXTURE_OPP}"] td:nth-child(2)`);
    await waitForDetailSettled(page);
const r2 = await domProbe(page, 'Pursuit detail');
    check('detail title shows the payload as literal text',
          await page.evaluate(() => document.querySelector('.dtt').innerText.includes('<i data-audit-probe=1>probe</i>')));
    check("the Opportunity-name input's value attribute holds the raw name intact",
          await page.evaluate(() => document.querySelector('[data-ed="name"]').value.includes('<i data-audit-probe=1>probe</i>')));
    await page.click('#dBack');
    await page.waitForTimeout(300);

    console.log("\n=== another pursuit's Depends-on picker (option labels) ===");
    await page.fill('#fq', dependent.name);
    await page.waitForTimeout(300);
    await page.click(`#pursuits tbody tr[data-uid="${DEPENDENT_OPP}"] td:nth-child(2)`);
    await waitForDetailSettled(page);
await domProbe(page, 'Depends-on picker');
    check('the Depends-on option label carries the payload as literal text',
          await page.evaluate(() => [...document.querySelectorAll('[data-ed="dependsOn"] option')]
                                     .some(o => o.textContent.includes('<i data-audit-probe=1>probe</i>'))));
    await page.click('#dBack');
    await page.waitForTimeout(300);

    console.log('\n=== Sandbox (table + questionnaire header) ===');
    await page.click('#nav a[data-v="sandbox"]');
    await page.waitForSelector('#sandbox table', { timeout: 10000 });
    await page.click(`#sandbox [data-q="${FIXTURE_OPP}"]`);
    await page.waitForSelector('#sbq .card', { timeout: 10000 });
    const r3 = await domProbe(page, 'Sandbox');
    check('Sandbox questionnaire header shows the payload as literal text',
          await page.evaluate(() => document.querySelector('#sbq h3').innerText.includes('<i data-audit-probe=1>probe</i>')));

    console.log('\n=== B&P / Investment tables ===');
    await page.click('#nav a[data-v="bp"]');
    await page.waitForTimeout(300);
    await domProbe(page, 'B&P view');

    console.log('\n=== CSP blocks inline script even when escaping is bypassed ===');
    const before = await page.evaluate(() => window.__cspv.length);
    await page.evaluate(() => {
      const s = document.createElement('script');
      s.textContent = 'window.__inline = 1';
      document.body.appendChild(s);                         // no nonce -> must be blocked
      const d = document.createElement('div');
      d.setAttribute('onclick', 'window.__attr = 1');
      document.body.appendChild(d);
      d.click();                                            // inline handler attribute -> must be blocked
    });
    // securitypolicyviolation events are dispatched asynchronously -- give
    // the browser a tick before counting them.
    await page.waitForTimeout(300);
    const blocked = await page.evaluate(b => ({
      inline: window.__inline, attr: window.__attr, violations: window.__cspv.length - b,
      sample: window.__cspv.slice(-2),
    }), before);
    check('an injected inline <script> without the nonce did NOT execute', blocked.inline === undefined, JSON.stringify(blocked));
    check('an injected inline onclick= attribute did NOT execute', blocked.attr === undefined, JSON.stringify(blocked));
    check('the browser reported securitypolicyviolation events for both', blocked.violations >= 2, JSON.stringify(blocked));
  } finally {
    if (browser) await browser.close();
    const restored = await api.patch(`/api/pursuits/${fixture.id}`, { data: { name: origName } });
    const after = await (await api.get('/api/bootstrap')).json();
    const now = after.pursuits.find(p => String(p.opp_id) === FIXTURE_OPP);
    check('cleanup: fixture name restored via the real PATCH endpoint',
          restored.ok() && now && now.name === origName, `now=${now && now.name}`);
    await api.dispose();
  }

  console.log(`\n${'='.repeat(58)}\n${PASS.length} passed, ${FAIL.length} failed`);
  if (FAIL.length) { console.log('\nFAILURES:'); FAIL.forEach(f => console.log('  - ' + f)); process.exit(1); }
  console.log('XSS escaping + CSP verified.');
})().catch(e => { console.error('TEST CRASHED:', e); process.exit(1); });
