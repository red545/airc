// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// arcbench.py's page beacon, injected into every served page. It reports, in epoch milliseconds from the page's own
// clock (performance.timeOrigin + high-resolution time): the first contentful paint, load, visibility changes and the
// first frame after the page becomes visible (requestAnimationFrame's frame time, and the moment that frame's
// main-thread work is done), focus and blur, and keydowns that reach the page (the driver's delivery calibration).
(() => {
  const id = new URL(document.currentScript.src).searchParams.get('id');
  const at = (ms) => performance.timeOrigin + ms;
  const send = (ev, extra) => {
    const body = JSON.stringify(Object.assign({ id, ev, t: at(performance.now()), vis: document.visibilityState,
                                                focus: document.hasFocus() }, extra || {}));
    try { fetch('/__beacon', { method: 'POST', body, keepalive: true }); } catch (e) { /* the server is gone */ }
  };
  const frame = (ev, start) => requestAnimationFrame((ts) => {
    const raf = at(ts);
    const ch = new MessageChannel();
    ch.port1.onmessage = () => send(ev, { start, raf, after: at(performance.now()) });
    ch.port2.postMessage(0);
  });
  send('script');
  try {
    new PerformanceObserver((list) => {
      for (const e of list.getEntries()) if (e.name === 'first-contentful-paint') send('fcp', { fcp: at(e.startTime) });
    }).observe({ type: 'paint', buffered: true });
  } catch (e) { /* no paint timing */ }
  addEventListener('load', () => setTimeout(() => send('load', { title: document.title }), 0));
  document.addEventListener('visibilitychange', (e) => {
    const start = at(e.timeStamp);
    send('vis', { start });
    if (document.visibilityState === 'visible') frame('visframe', start);
  });
  addEventListener('blur', (e) => send('blur', { start: at(e.timeStamp) }));
  addEventListener('focus', (e) => send('focus', { start: at(e.timeStamp) }));
  addEventListener('keydown', (e) => send('key', { start: at(e.timeStamp), key: e.key }), true);
})();
