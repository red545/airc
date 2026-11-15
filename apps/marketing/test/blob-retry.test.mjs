import assert from 'node:assert/strict';
import { test } from 'node:test';
import * as sdk from '@vercel/blob';
import { blobCall, transient, Unavailable } from '../api/_lib/blob-retry.js';
import { blobStore, resetMemoryStore, memoryStore, update } from '../api/_lib/store.js';
import { limit } from '../api/_lib/rate.js';
import { GET } from '../api/share.js';
const failure = (status) => Object.assign(new Error(`Failed to fetch blob: ${status} test`), { status });
const response = () => ({ statusCode: 200, stream: new Blob(['{}']).stream(), blob: { etag: '"one"', contentType: 'application/json' } });
const request = () => new Request('https://test.example/api/share?id=Abcdef123456');
test('transient Blob read succeeds on second attempt', async () => {
 let n=0;
 const s=await blobStore('fake', {...sdk, get: async()=>{if (++n===1) throw failure(500); return response();}});
 assert.equal((await s.get('x')).text,'{}'); assert.equal(n,2);
});
test('persistent 500 yields sanitized JSON 503 with Retry-After', async()=>{
 let n=0;
 Object.assign(resetMemoryStore(),await blobStore('fake',{...sdk,get:async()=>{n++;throw failure(500);}}));
 const r=await GET(request()); assert.equal(r.status,503); assert.equal(r.headers.get('retry-after'),'2');
 assert.equal((await r.json()).error,'unavailable'); assert.equal(n,3);
});
test('404 is not retried and share stays 404',async()=>{
 let n=0;
 Object.assign(resetMemoryStore(),await blobStore('fake',{...sdk,get:async()=>{n++;throw new sdk.BlobNotFoundError();}}));
 assert.equal((await GET(request())).status,404); assert.equal(n,1);
});
test('only transient errors retry, with bounded jitter',async()=>{
 for(const status of [400,401,403,404,409,412]) {
 let n=0;await assert.rejects(blobCall(async()=>{n++;throw failure(status);}),Unavailable);assert.equal(n,1);
 }
 for(const e of [failure(429),failure(502),new sdk.BlobServiceNotAvailable(),new sdk.BlobServiceRateLimited(),new TypeError('fetch failed')]) assert.ok(transient(e));
 assert.equal(transient(new Error('bug')),false);
 const delays=[];let n=0;
 await assert.rejects(blobCall(async()=>{n++;throw failure(500);},{sleep:async(ms)=>{delays.push(ms);},random:()=>0.5}),Unavailable);
 assert.deepEqual(delays,[75,150]);assert.equal(n,3);
 n=0;await assert.rejects(blobCall(async()=>{n++;throw new sdk.BlobServiceRateLimited(20);}),Unavailable);assert.equal(n,1);
});
test('deadline aborts hung operation and observes late rejection',async()=>{
 let signal;
 await assert.rejects(blobCall((s)=>{signal=s;return new Promise((_,reject)=>setTimeout(()=>reject(new Error('late')),30));},{budgetMs:10}),Unavailable);
 assert.ok(signal.aborted);await new Promise(r=>setTimeout(r,40));
});
test('overwrite, delete and list recover',async()=>{
 const counts={put:0,del:0,list:0};const fake={...sdk};
 for(const method of Object.keys(counts)) fake[method]=async()=>{if(++counts[method]===1)throw failure(503);return method==='put'?{etag:'ok'}:{blobs:[],hasMore:false};};
 const s=await blobStore('fake',fake);assert.equal(await s.put('file','{}',{overwrite:true}),'ok');await s.del('file');assert.deepEqual(await s.list('files/'),[]);assert.deepEqual(counts,{put:2,del:2,list:2});
});
test('lost create/CAS response cannot double-count rate limit or update',async()=>{
 process.env.SHARING_MEMORY_STORE='1';
 for(const existing of [false,true])for(const kind of ['rate','update']){
 const memory=memoryStore();let writes=0,key;
 const s=await blobStore('fake',{...sdk,put:async(k,body,options)=>{writes++;key=k;await memory.put(k,body,options);throw failure(500);}});
 s.get=async(k)=>{if(existing&&!await memory.get(k))await memory.put(k,'{"n":7}');return memory.get(k);};s.del=memory.del;
 await assert.rejects(kind==='rate'?limit(s,request(),'share'):update(s,'counter',old=>({n:(old?.n??0)+1})),Unavailable);
 assert.equal(writes,1);assert.equal(JSON.parse((await memory.get(key)).text).n,existing?8:1);assert.equal(process.env.VERCEL_BLOB_RETRIES,'0');
 }
});
