#!/usr/bin/env node
// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Node 22+. A fresh scratch directory is required. No Google credentials involved.
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
const [app, scratch, scenario] = process.argv.slice(2);
if (!app || !scratch) throw Error('Usage: node engine/host/acceptance.mjs <AircHost.app> <new scratch directory>');
await fs.mkdir(scratch); // Refuse to erase or reuse a real profile.
const dir = path.resolve(scratch);
await fs.mkdir(path.join(dir, "Chromium"));
if (scenario === 'download' || scenario === 'pass13') {
  const profile = path.join(dir, 'Chromium', 'Profile One');
  await fs.mkdir(profile, { recursive: true });
  await fs.mkdir(path.join(dir, 'downloads'));
  await fs.writeFile(path.join(profile, 'Preferences'), JSON.stringify({download: {default_directory: path.join(dir, 'downloads'), prompt_for_download: false}}));
}
const pass13Page = scenario === 'pass13' ? await fs.readFile(new URL('./pass13.html', import.meta.url)) : null;
let allowRetry = false;
const server = createServer((req, res) => {
  if (scenario === 'pass13') {
    if (req.url === '/allow-retry') { allowRetry = true; res.writeHead(204); res.end(); return; }
    if (req.url === '/art.svg') { res.writeHead(200, {'Content-Type':'image/svg+xml'}); res.end('<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96"><rect width="96" height="96" fill="blue"/></svg>'); return; }
    if (req.url === '/tone.wav') {
      const data = Buffer.alloc(44 + 16000 * 2 * 8); // eight seconds of synthetic silence
      data.write('RIFF');data.writeUInt32LE(data.length-8,4);data.write('WAVEfmt ',8);data.writeUInt32LE(16,16);
      data.writeUInt16LE(1,20);data.writeUInt16LE(1,22);data.writeUInt32LE(16000,24);data.writeUInt32LE(32000,28);
      data.writeUInt16LE(2,32);data.writeUInt16LE(16,34);data.write('data',36);data.writeUInt32LE(data.length-44,40);
      res.writeHead(200,{'Content-Type':'audio/wav'});res.end(data);return;
    }
    if (['/slow','/interrupt','/danger'].includes(req.url)) {
      const dangerous = req.url === '/danger';
      const interrupt = req.url === '/interrupt' && !allowRetry;
      const length = dangerous ? 32 : 1048576;
      res.writeHead(200, {'Content-Type':'application/octet-stream','Content-Length':length,
        'Content-Disposition':`attachment; filename="${dangerous ? 'inert.command' : req.url === '/slow' ? 'slow.bin' : 'retry.bin'}"`});
      if (dangerous) { res.end(Buffer.alloc(32));return; }
      // Deliver headers and a body chunk before disconnecting: destroying the
      // socket with the first write lets the network layer retry transparently.
      res.flushHeaders();
      let sent = 0;
      const timer = setInterval(()=>{
        res.write(Buffer.alloc(32768, 65));sent += 32768;
        if ((interrupt && sent >= 65536) || sent >= length) { clearInterval(timer); if (interrupt) res.destroy(); else res.end(); }
      },100);
      res.on('close',()=>clearInterval(timer));return;
    }
    res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store'});res.end(pass13Page);return;
  }
  if (scenario === 'dialogs' && req.url === '/auth') {
    res.writeHead(401, {'WWW-Authenticate': 'Basic realm="Synthetic Airc dialog"'});
    res.end('Synthetic auth cancelled'); return;
  }
  if (scenario === 'pass12' || scenario === 'forms' || scenario === 'autofill' || scenario === 'native' || scenario?.startsWith('safestorage')) {
    res.writeHead(200, {'Content-Type': 'text/html', 'Cache-Control': 'no-store'});
    if (req.url.startsWith('/submitted')) res.end('<!doctype html><title>Signed in fixture</title>Success');
    else if (scenario === 'autofill') {
      const fields = req.url.startsWith('/card')
        ? [['cc-name','Name'],['cc-number','Card number'],['cc-exp-month','Month'],['cc-exp-year','Year']]
        : [['given-name','First name'],['family-name','Last name'],['street-address','Address'],['address-level2','City'],['address-level1','State'],['postal-code','ZIP'],['country','Country']];
      res.end('<!doctype html><title>Synthetic autofill</title><form action="/submitted" method="post">' +
        fields.map(([id,label]) => `<label>${label}<input id="${id}" name="${id}" autocomplete="${id}"></label>`).join('') +
        '<button id="submit">Submit</button></form>');
    }
    else res.end(`<!doctype html><title>Synthetic forms</title>
      <form action="/submitted" method="post">
      <label>User <input id="username" name="username" autocomplete="username"></label>
      <label>Password <input id="password" name="password" type="password" autocomplete="current-password"></label>
      <button id="submit">Sign in</button></form>
      <input id="upload" type="file" onchange="window.fileChanged=true" oncancel="window.fileCancelled=true">`);
    req.resume(); return;
  }
  if (req.url === '/download') {
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Disposition': 'attachment; filename="fixture.txt"' });
    res.end('Airc download fixture\n'); return;
  }
  res.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
  res.end('<!doctype html><title>Airc profile isolation</title><body style="height:5000px"><p>Local profile isolation fixture</p><input></body>');
});
// safestorage relaunches on another framework: the login's origin (its port) must stay the same.
await new Promise(resolve => server.listen(scenario?.startsWith('safestorage') ? Number(process.env.AIRC_HOST_PORT || 18594) : 0, '127.0.0.1', resolve));
const url = scenario === "extension" ? "https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh" : `http://${scenario === "dialogs" ? "localhost" : "127.0.0.1"}:${server.address().port}/`;
// safestorage-*: no system prompt may be up before, during or after a keychain launch (lead 2026-11-19). AIRC_PROMPTWATCH
// is promptwatch.swift built: on-screen SecurityAgent/UserNotificationCenter windows and their PIDs. A prompt stops the
// case at once (our host is stopped by its PID) and the whole scenario ends with "PROMPT …"; never waited out.
const promptwatch = scenario?.startsWith('safestorage-') ? process.env.AIRC_PROMPTWATCH : null;
if (scenario?.startsWith('safestorage-') && !promptwatch) throw Error('AIRC_PROMPTWATCH is required for the keychain cases');
async function prompts() { return JSON.parse((await exec(promptwatch, [])).out); }
const promptUp = p => p.windows.length > 0 || p.userNotificationCenter.length > 0;
async function stopHost(host) {
  // open -W is a launcher, not the app. Kill only the PID recorded by this fresh host instance, after checking its
  // executable; never kill by name.
  try {
    const pid = (await fs.readFile(path.join(dir, `${currentPhase}.pid`), 'utf8')).trim();
    if (/^[1-9][0-9]*$/.test(pid)) {
      const ps = spawn('/bin/ps', ['-p', pid, '-o', 'comm=']);
      let command = '';
      ps.stdout.on('data', data => { command += data; });
      await new Promise(resolve => ps.once('close', resolve));
      if (command.trim() === path.resolve(host, 'Contents/MacOS/AircHost')) {
        const kill = spawn('/bin/kill', ['-TERM', pid]);
        await new Promise(resolve => kill.once('close', resolve));
      }
    }
  } catch { /* A host that never started has no PID file. */ }
}
let currentPhase = '';
async function run(phase, host = app, testValues = '') {
  currentPhase = phase;
  const before = promptwatch ? await prompts() : null;
  if (before && promptUp(before)) throw Error(`PROMPT before ${phase}: ${JSON.stringify(before)}`);
  const result = await runPhase(phase, host, testValues, before);
  if (before) {
    const after = await prompts();
    const newAgents = after.securityAgent.filter(pid => !before.securityAgent.includes(pid));
    if (promptUp(after) || newAgents.length) throw Error(`PROMPT after ${phase}: ${JSON.stringify(after)} (SecurityAgent before: ${JSON.stringify(before.securityAgent)})`);
  }
  return result;
}
async function runPhase(phase, host, testValues, before) {
  const report = path.join(dir, `${phase}.json`);
  const log = await fs.open(path.join(dir, `${phase}.log`), 'w');
  try {
    const child = spawn('/usr/bin/open', ['-g', '-n', '-W', '--stdout', path.join(dir, `${phase}.app.log`), '--stderr', path.join(dir, `${phase}.app.log`), path.resolve(host), '--args',
      `--user-data-dir=${dir}/Chromium`, `--airc-data-dir=${dir}`, process.env.AIRC_NATIVE_CASE === "context" ? "--airc-test=memoryPressure" : `--airc-test=memoryPressure,contextMenu,modalDialogs${['pass12','pass13'].includes(scenario) ? ',systemMediaPermission=granted' : ''}${testValues ? ',' + testValues : ''}`, `--airc-smoke=${phase}`, `--airc-test-url=${url}`,
      `--airc-extension-fixture=${path.resolve("engine/host/extension-fixture")}`, `--airc-native-case=${process.env.AIRC_NATIVE_CASE || "all"}`, `--airc-report=${report}`, `--airc-pid=${dir}/${phase}.pid`, `--airc-screenshot=${dir}/${phase}.png`, '--use-mock-keychain', '--disable-backgrounding-occluded-windows', '--use-fake-device-for-media-stream',
      ...(process.env.AIRC_NATIVE_CASE === 'media' || (scenario === 'pass13' && process.env.AIRC_CAPTURE_INDICATOR !== '1') ? ['--use-fake-ui-for-media-stream'] : []),
      ...(scenario === 'pass13' ? ['--autoplay-policy=no-user-gesture-required'] : []),
    ], { stdio: ['ignore', log.fd, log.fd] });
    await new Promise((resolve, reject) => {
      let watching = false;
      const watch = before && setInterval(async () => {
        if (watching) return;
        watching = true;
        const now = await prompts().catch(() => null);
        watching = false;
        if (!now || !promptUp(now)) return;
        clearInterval(watch); clearTimeout(timer);
        await stopHost(host);
        child.kill('SIGTERM');
        reject(Error(`PROMPT during ${phase}: ${JSON.stringify(now)}`));
      }, 2000);
      const timer = setTimeout(async () => {
        if (watch) clearInterval(watch);
        await stopHost(host);
        child.kill('SIGTERM');
        reject(Error(`${phase}: 120s timeout`));
      }, 120000);
      child.once('error', error => { clearTimeout(timer); if (watch) clearInterval(watch); reject(error); });
      child.once('exit', code => { clearTimeout(timer); if (watch) clearInterval(watch); code === 0 ? resolve() : reject(Error(`${phase}: exit ${code}`)); });
    });
    const appLog = await fs.readFile(path.join(dir, `${phase}.app.log`), 'utf8');
    if (/Received signal|FATAL:|Check failed:/.test(appLog)) throw Error(`${phase}: native crash in app log`);
    const result = JSON.parse(await fs.readFile(report, 'utf8'));
    if (!result.ok || (['write', 'read', 'keyblocked'].includes(phase) && Object.keys(result.profiles).length !== 2)) throw Error(JSON.stringify(result));
    console.log(`PASS ${phase} (${path.basename(host)}): ${['write', 'read'].includes(phase) ? "two profiles, isolated persistent cookie and localStorage" : "scenario assertions"}`);
    return result;
  } finally { await log.close(); }
}
// safestorage-file / safestorage-scratch: the Safe Storage guard (engine patch 041, airc_safe_storage.mm) with the
// file keychain (--airc-test=keychain=file) or a scratch keychain made here (<dir>/Scratch.keychain-db, its own
// HOME so the user's keychain search list is never touched; reads never ask). Cases: (a) first run makes the key;
// (b) denied/locked, (c) an access list that doesn't trust the app, (d) a different key, and a missing item on a
// data dir that holds data: the app asks (Try Again / Continue Without Saved Passwords for Now / Quit), makes and
// replaces nothing, and the saved cookies and logins are byte-identical and decrypt once access is back.
const chromium = path.join(dir, 'Chromium');
const testLog = path.join(chromium, 'Test Safe Storage Log');
const keyFile = path.join(chromium, 'Test Safe Storage Key');
const keyCheck = path.join(chromium, 'Airc Safe Storage Check');
const scratchKeychain = path.join(dir, 'Scratch.keychain-db');
const scratchHome = path.join(dir, 'keychain-home');
const scratchPassword = 'made-up-scratch-keychain';
const scratchKey = 'made-up-safe-storage-key-1';
async function exec(file, args, env = {}) {
  const child = spawn(file, args, { env: { ...process.env, ...env } });
  let out = '', err = '';
  child.stdout.on('data', d => { out += d; }); child.stderr.on('data', d => { err += d; });
  const code = await new Promise(resolve => child.once('close', resolve));
  return { code, out, err };
}
async function readOr(file, fallback = null) { try { return await fs.readFile(file); } catch { return fallback; } }
async function databases(name) {
  const found = [];
  async function walk(d) {
    for (const e of await fs.readdir(d, { withFileTypes: true }).catch(() => [])) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) await walk(p); else if (e.name === name) found.push(p);
    }
  }
  await walk(chromium);
  return found.sort();
}
// The saved data as stored: every cookie's and login's ciphertext (hex), per database.
async function snapshot() {
  const out = { cookies: {}, logins: {} };
  for (const db of await databases('Cookies'))
    out.cookies[path.relative(chromium, db)] = (await exec('/usr/bin/sqlite3', ['-readonly', db, "select host_key||' '||name||' '||value||' '||hex(encrypted_value) from cookies order by 1"])).out;
  for (const db of await databases('Login Data'))
    out.logins[path.relative(chromium, db)] = (await exec('/usr/bin/sqlite3', ['-readonly', db, "select origin_url||' '||username_value||' '||hex(password_value) from logins order by 1"])).out;
  return out;
}
function countRows(snap, kind) { return Object.values(snap[kind]).join('').split('\n').filter(Boolean).length; }
async function keychainState() { return { key: (await readOr(keyFile))?.toString('hex') ?? null, check: (await readOr(keyCheck))?.toString() ?? null }; }
async function logSince(offset) { return ((await readOr(testLog, Buffer.alloc(0))).subarray(offset)).toString(); }
async function logSize() { return (await readOr(testLog, Buffer.alloc(0))).length; }
const steps = [];
function expect(ok, what) { steps.push({ ok: !!ok, what }); console.log(`${ok ? 'PASS' : 'FAIL'} ${what}`); }
async function security(args) { return exec('/usr/bin/security', args, { HOME: scratchHome, CFFIXED_USER_HOME: scratchHome }); }
async function blocked(label, values, problem, seen, { answers = 'continue', alerts = 1 } = {}) {
  const before = await snapshot(), keys = await keychainState(), offset = await logSize();
  const result = await run('keyblocked', app, `${values},safeStorageAnswer=${answers}`);
  // The alert's text has a blank line in it: one log entry spans lines.
  const log = (await logSince(offset)).replace(/\n\n/g, ' '), after = await snapshot();
  const asked = log.split('\n').filter(l => l.startsWith('alert '));
  expect(asked.length === alerts && asked.every(l => l.startsWith(`alert ${problem} `)), `${label}: asked ${alerts}x (${problem}): ${asked.map(l => l.split(' || ')[0]).join(' / ')}`);
  expect(seen.test(log), `${label}: the test keychain answered as set up (${seen})`);
  expect(asked.length && asked.every(l => l.includes('Continue Without Saved Passwords for Now') && l.includes('Try Again') && l.includes('Quit')), `${label}: the message offers Try Again, Continue Without Saved Passwords for Now and Quit`);
  expect(/answer Continue Without Saved Passwords for Now/.test(log), `${label}: continued without saved passwords`);
  expect(!/add created|scratch add|read created|refused/.test(log), `${label}: no key was made, replaced or deleted`);
  expect(JSON.stringify(await keychainState()) === JSON.stringify(keys), `${label}: key and key check unchanged`);
  expect(JSON.stringify(after) === JSON.stringify(before), `${label}: saved cookies (${countRows(before, 'cookies')}) and logins (${countRows(before, 'logins')}) byte-identical`);
  expect(['one', 'two'].every(p => result.profiles[p]?.before === ''), `${label}: saved cookies unreadable without the key (page saw ${JSON.stringify(result.profiles.one?.before)})`);
  return log;
}
async function restored(label, values) {
  const offset = await logSize();
  try {
    await run('read', app, values);
    const filled = await run('forms-read', app, values);
    expect(filled.profiles?.passwordFilled, `${label}: access back: cookies decrypt in both profiles and the saved login fills`);
  } catch (error) {
    if (error.message.startsWith('PROMPT')) throw error;
    expect(false, `${label}: access back: ${error.message.slice(0, 300)}`);
  }
  return logSince(offset);
}

try {
  if (scenario === 'safestorage-file' || scenario === 'safestorage-scratch') {
    const file = scenario === 'safestorage-file';
    const kc = file ? 'keychain=file' : `keychain=scratch,keychainPassword=${scratchPassword}`;
    const realList = (await exec('/usr/bin/security', ['list-keychains', '-d', 'user'])).out;
    if (!file) {
      await fs.mkdir(scratchHome);
      for (const args of [['create-keychain', '-p', scratchPassword, scratchKeychain], ['set-keychain-settings', scratchKeychain],
                          ['add-generic-password', '-s', 'Airc Safe Storage', '-a', 'Airc', '-w', scratchKey, '-A', scratchKeychain]]) {
        const r = await security(args); if (r.code) throw Error(`security ${args[0]}: ${r.err}`);
      }
    }
    // (a) first run: the item is missing on a fresh data dir, so the key is made (file) / the scratch item is read.
    let offset = await logSize();
    await run('write', app, kc);
    let log = await logSince(offset);
    if (file) expect(/find missing/.test(log) && /add created/.test(log) && /read created/.test(log) && (await readOr(keyFile))?.length, '(a) first run: item missing on a fresh data dir, key created (add-if-absent)');
    else expect(/scratch find found/.test(log), '(a) first run: the scratch keychain item is read');
    expect(/key check written/.test(log) && await readOr(keyCheck), '(a) key check written with the first key');
    await run('forms', app, kc);
    const saved = await snapshot();
    expect(countRows(saved, 'cookies') >= 2 && countRows(saved, 'logins') >= 1 && Object.values(saved.cookies).join('').includes('763130'), `saved: ${countRows(saved, 'cookies')} cookies, ${countRows(saved, 'logins')} login(s), encrypted (v10)`);
    log = await restored('(a) relaunch', kc);
    expect(/read ok/.test(log) && !/created/.test(log), '(a) relaunch reads the same key, makes none');
    if (file) {
      // errSecAuthFailed: the person denied macOS's prompt, which is also what (c) gives when the item's access list
      // no longer trusts this build (a re-sign). A real access-list read can raise macOS's own dialog, so it's never run.
      await blocked('(b)/(c) denied (prompt denied; access list not trusting this build)', `${kc},keychainFail=denied`, 'locked', /find failed -25293/);
      await blocked('(b) locked, Try Again then Continue', `${kc},keychainFail=locked`, 'locked', /find failed -25308[^]*find failed -25308/, { answers: 'retry+continue', alerts: 2 });
      await blocked('(b) prompt cancelled', `${kc},keychainFail=canceled`, 'locked', /find failed -128/);
      await restored('(b) after access is back', kc);
      // Missing item on a data dir that holds data (a keychain reset or switch): never a new key on its own.
      const key = await fs.readFile(keyFile);
      await fs.rename(keyFile, keyFile + '.aside');
      log = await blocked('missing item with saved data', kc, 'missing', /find missing/);
      expect(/not creating/.test(log) && !(await readOr(keyFile)), 'missing item with saved data: no new key made');
      await fs.rename(keyFile + '.aside', keyFile);
      // Try Again works in the same launch: the item shows up for the second read.
      offset = await logSize();
      await run('read', app, `${kc},keychainHiddenReads=1,safeStorageAnswer=retry`);
      log = await logSince(offset);
      expect(/find hidden/.test(log) && /alert missing/.test(log) && /answer Try Again/.test(log) && /read ok/.test(log), 'Try Again: the second read in the same launch opens the cookies');
      // (d) a different key: refused, never written over the key check.
      await fs.writeFile(keyFile, 'made-up-different-key-2');
      await blocked('(d) different key', kc, 'wrong-key', /find found[^]*read wrong key/);
      await fs.writeFile(keyFile, key);
      await restored('(d) after the right key is back', kc);
    } else {
      // Lock state is per login session, so the app locks it (SecKeychainLock) right after opening it.
      await blocked('(b) locked keychain', `${kc},keychainLock=1`, 'locked', /scratch lock 0[^]*scratch find locked/);
      await restored('(b) after unlocking', kc);
      // (d) a different key in the item: refused.
      await security(['delete-generic-password', '-s', 'Airc Safe Storage', '-a', 'Airc', scratchKeychain]);
      await security(['add-generic-password', '-s', 'Airc Safe Storage', '-a', 'Airc', '-w', 'made-up-different-key-2', '-A', scratchKeychain]);
      await blocked('(d) different key', kc, 'wrong-key', /scratch find found[^]*read wrong key/);
      await security(['delete-generic-password', '-s', 'Airc Safe Storage', '-a', 'Airc', scratchKeychain]);
      await security(['add-generic-password', '-s', 'Airc Safe Storage', '-a', 'Airc', '-w', scratchKey, '-A', scratchKeychain]);
      await restored('(d) after the right key is back', kc);
      await security(['delete-keychain', scratchKeychain]);
    }
    expect((await exec('/usr/bin/security', ['list-keychains', '-d', 'user'])).out === realList, "the user's keychain search list is unchanged");
    const alerts = (await fs.readdir(chromium)).filter(n => n.startsWith('Test Safe Storage Alert'));
    expect(alerts.length > 0, `the message showed (${alerts.length} alert pictures)`);
    await fs.writeFile(path.join(dir, 'results.json'), JSON.stringify(steps, null, 2));
    const failed = steps.filter(s => !s.ok).length;
    console.log(`${failed ? 'FAIL' : 'PASS'} ${scenario}: ${steps.length - failed}/${failed}`);
    if (failed) process.exitCode = 1;
  } else if (scenario === 'safestorage') {
    // Safe Storage across an engine update (mock keychain): AIRC_WRITE_APP (the older framework's host) writes
    // encrypted cookies, localStorage and a saved login; <AircHost.app> (the newer one) reads and fills them.
    const old = process.env.AIRC_WRITE_APP || app;
    const results = {write: await run('write', old), forms: await run('forms', old), read: await run('read'), formsRead: await run('forms-read')};
    if (!results.formsRead.profiles?.passwordFilled) throw Error('forms-read: the saved login did not fill');
    await fs.writeFile(path.join(dir, 'results.json'), JSON.stringify(results, null, 2));
    console.log(`PASS safestorage: ${path.basename(old)} wrote, ${path.basename(app)} decrypted cookies and filled the saved login`);
  } else if (scenario) { console.log(JSON.stringify(await run(scenario), (key, value) => key === "icon" ? "[PNG data URL]" : value)); if (scenario === 'pass13') console.log(JSON.stringify(await run('pass13-read'))); } else {
  const write = await run('write');
  const read = await run('read');
  await fs.writeFile(path.join(dir, 'results.json'), JSON.stringify({ write, read }, null, 2));
  console.log('PASS restart restored both profiles. Real Google account acceptance remains manual.');
  }
} finally { server.close(); }
