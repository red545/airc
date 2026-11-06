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
  if (scenario === 'pass12' || scenario === 'forms' || scenario === 'autofill' || scenario === 'native') {
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
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const url = scenario === "extension" ? "https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh" : `http://${scenario === "dialogs" ? "localhost" : "127.0.0.1"}:${server.address().port}/`;
async function run(phase) {
  const report = path.join(dir, `${phase}.json`);
  const log = await fs.open(path.join(dir, `${phase}.log`), 'w');
  try {
    const child = spawn('/usr/bin/open', ['-g', '-n', '-W', '--stdout', path.join(dir, `${phase}.app.log`), '--stderr', path.join(dir, `${phase}.app.log`), path.resolve(app), '--args',
      `--user-data-dir=${dir}/Chromium`, `--airc-data-dir=${dir}`, process.env.AIRC_NATIVE_CASE === "context" ? "--airc-test=memoryPressure" : `--airc-test=memoryPressure,contextMenu,modalDialogs${['pass12','pass13'].includes(scenario) ? ',systemMediaPermission=granted' : ''}`, `--airc-smoke=${phase}`, `--airc-test-url=${url}`,
      `--airc-extension-fixture=${path.resolve("engine/host/extension-fixture")}`, `--airc-native-case=${process.env.AIRC_NATIVE_CASE || "all"}`, `--airc-report=${report}`, `--airc-pid=${dir}/${phase}.pid`, `--airc-screenshot=${dir}/${phase}.png`, '--use-mock-keychain', '--disable-backgrounding-occluded-windows', '--use-fake-device-for-media-stream',
      ...(process.env.AIRC_NATIVE_CASE === 'media' || (scenario === 'pass13' && process.env.AIRC_CAPTURE_INDICATOR !== '1') ? ['--use-fake-ui-for-media-stream'] : []),
      ...(scenario === 'pass13' ? ['--autoplay-policy=no-user-gesture-required'] : []),
    ], { stdio: ['ignore', log.fd, log.fd] });
    await new Promise((resolve, reject) => {
      const timer = setTimeout(async () => {
        // open -W is a launcher, not the app. Kill only the PID recorded by this
        // fresh host instance, after checking its executable; never kill by name.
        try {
          const pid = (await fs.readFile(path.join(dir, `${phase}.pid`), 'utf8')).trim();
          if (/^[1-9][0-9]*$/.test(pid)) {
            const ps = spawn('/bin/ps', ['-p', pid, '-o', 'comm=']);
            let command = '';
            ps.stdout.on('data', data => { command += data; });
            await new Promise(resolve => ps.once('close', resolve));
            if (command.trim() === path.resolve(app, 'Contents/MacOS/AircHost')) {
              const kill = spawn('/bin/kill', ['-TERM', pid]);
              await new Promise(resolve => kill.once('close', resolve));
            }
          }
        } catch { /* A host that never started has no PID file. */ }
        child.kill('SIGTERM');
        reject(Error(`${phase}: 120s timeout`));
      }, 120000);
      child.once('error', error => { clearTimeout(timer); reject(error); });
      child.once('exit', code => { clearTimeout(timer); code === 0 ? resolve() : reject(Error(`${phase}: exit ${code}`)); });
    });
    const appLog = await fs.readFile(path.join(dir, `${phase}.app.log`), 'utf8');
    if (/Received signal|FATAL:|Check failed:/.test(appLog)) throw Error(`${phase}: native crash in app log`);
    const result = JSON.parse(await fs.readFile(report, 'utf8'));
    if (!result.ok || (!scenario && Object.keys(result.profiles).length !== 2)) throw Error(JSON.stringify(result));
    console.log(`PASS ${phase}: ${scenario ? "scenario assertions" : "two profiles, isolated persistent cookie and localStorage"}`);
    return result;
  } finally { await log.close(); }
}
try {
  if (scenario) { console.log(JSON.stringify(await run(scenario), (key, value) => key === "icon" ? "[PNG data URL]" : value)); if (scenario === 'pass13') console.log(JSON.stringify(await run('pass13-read'))); } else {
  const write = await run('write');
  const read = await run('read');
  await fs.writeFile(path.join(dir, 'results.json'), JSON.stringify({ write, read }, null, 2));
  console.log('PASS restart restored both profiles. Real Google account acceptance remains manual.');
  }
} finally { server.close(); }
