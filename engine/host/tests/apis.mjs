// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
const [app, output] = process.argv.slice(2);
const out = path.resolve(output);
await fs.mkdir(out); // fresh scratch data only
const server = createServer((req,res)=>{
  if (req.url === '/art.svg') {
    res.writeHead(200, {'Content-Type':'image/svg+xml'});
    res.end('<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect width="20" height="20" fill="yellow"/></svg>');
  } else {
    res.writeHead(200, {'Content-Type':'text/html'});
    res.end('<!doctype html><title>Airc API fixture</title><body style="margin:0;background:linear-gradient(to right,#f00 50%,#00f 50%);height:100vh"><h1>Airc API fixture</h1><img src="/art.svg"></body>');
  }
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
try {
  const child = spawn('open',['-g','-n','-W','--stdout',`${out}/host.log`,'--stderr',`${out}/host.log`,path.resolve(app),'--args',
    `--user-data-dir=${out}/profile`,`--output=${out}`,`--fixture=http://127.0.0.1:${server.address().port}/`,
    '--use-mock-keychain','--disable-backgrounding-occluded-windows']);
  const code = await new Promise(r=>child.on('exit',r));
  const result = JSON.parse(await fs.readFile(`${out}/results.json`));
  console.log(JSON.stringify(result,null,2));
  const log = await fs.readFile(`${out}/host.log`, 'utf8');
  if (code || result.error || /Received signal|FATAL:|Check failed:/.test(log)) process.exitCode = 1;
} finally { server.close(); }
