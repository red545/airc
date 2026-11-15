// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Original Airc resource. No uBO code or list content is incorporated.
(() => {
  'use strict';
  const parse = JSON.parse;
  const own = (o, key) => Object.prototype.hasOwnProperty.call(o, key);
  // Touch only player responses. Leave media URLs, captions, timing and the
  // playback API intact; never skip by seeking or changing playback speed.
  function prune(value) {
    if (!value || typeof value !== 'object') return value;
    if (own(value, 'playabilityStatus') &&
        (own(value, 'videoDetails') || own(value, 'streamingData'))) {
      for (const key of ['adPlacements', 'playerAds', 'adSlots']) {
        try { delete value[key]; } catch (_) {}
      }
    }
    return value;
  }
  JSON.parse = function(...args) { return prune(Reflect.apply(parse, this, args)); };
  const descriptor = Object.getOwnPropertyDescriptor(window, 'ytInitialPlayerResponse');
  if (!descriptor || (descriptor.configurable && own(descriptor, 'value') && descriptor.writable)) {
    let response = prune(descriptor && descriptor.value);
    Object.defineProperty(window, 'ytInitialPlayerResponse', {
      configurable: true, enumerable: descriptor ? descriptor.enumerable : true,
      get() { return response; }, set(value) { response = prune(value); }
    });
  }
  const playerURL = value => {
    try {
      const u = new URL(value, location.href);
      return u.origin === location.origin && /^\/youtubei\/v1\/player\/?$/.test(u.pathname);
    } catch (_) { return false; }
  };
  // Response.json uses the browser's parser, not the replaceable JSON.parse.
  const responseJSON = Response.prototype.json;
  Response.prototype.json = function(...args) {
    const result = Reflect.apply(responseJSON, this, args);
    return playerURL(this.url) ? result.then(prune) : result;
  };
  // XHR's native getters are called first, retaining InvalidStateError and
  // responseType semantics. Only the same-origin player endpoint is eligible.
  for (const key of ['response', 'responseText']) {
    const d = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, key);
    if (!d || !d.get || !d.configurable) continue;
    Object.defineProperty(XMLHttpRequest.prototype, key, {...d, get() {
      const value = Reflect.apply(d.get, this, []);
      if (!playerURL(this.responseURL)) return value;
      if (this.responseType === 'json') return prune(value);
      if (typeof value !== 'string' || !value) return value;
      try { return JSON.stringify(prune(Reflect.apply(parse, JSON, [value]))); }
      catch (_) { return value; }
    }});
  }
})();
