// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
//
// The page script below is adapted from the FairPlay block of Ardia's page_script.js
// (https://github.com/ardia-browser/ardia, packages/ardiacore/ios/page_script.js), which is Copyright 2026 Mantra Patel,
// licensed under the Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0); modified by The Airc
// Authors: made a self-contained page-script part, with its own Media Session mirror, a test mode for clear playlists,
// and messages in Airc's part protocol.

import Foundation
import AircKit

/// The `fairplay` page-script part (docs/design/fairplay-bridge.md): on a listed origin's top frame, offers the page
/// Apple's FairPlay key system, takes the HLS playlist the player gives its media element, and answers that element
/// from the native player's reports. Everywhere else it returns at once.
enum FairPlayBridgeScript {
    /// `origins`: the exact origins it acts on. `clearTestOrigin`: a test page's origin where a playlist without a
    /// FairPlay key also goes to the native player (AIRC_TESTING only; nil in the app).
    static func source(origins: [String], clearTestOrigin: String?) -> String {
        func json(_ list: [String]) -> String {
            (try? JSONSerialization.data(withJSONObject: list, options: .withoutEscapingSlashes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        let list = json(origins), test = json(clearTestOrigin.map { [$0] } ?? [])
        return template
            .replacingOccurrences(of: "__AIRC_FAIRPLAY_ORIGINS__", with: list)
            .replacingOccurrences(of: "__AIRC_FAIRPLAY_CLEAR_TEST__", with: test)
            .replacingOccurrences(of: "__AIRC_FAIRPLAY_KEY_SYSTEM__", with: FairPlayBridgeSites.keySystem)
    }

    private static let template = #"""
function (post) {
  "use strict";
  var ORIGINS = __AIRC_FAIRPLAY_ORIGINS__, CLEAR_TEST = __AIRC_FAIRPLAY_CLEAR_TEST__;
  try {
    if (window !== window.top || ORIGINS.indexOf(location.origin) < 0) return null;
    if (typeof Navigator.prototype.requestMediaKeySystemAccess !== "function") return null;
  } catch (e) { return null; }
  const clearTest = CLEAR_TEST.indexOf(location.origin) >= 0;
  const KEY_SYSTEM = "__AIRC_FAIRPLAY_KEY_SYSTEM__";
  const PLAYLIST_PART = 30000;
  const SEEK_GIVE_UP_MS = 2000;
  const ENCRYPTED_DELAY_MS = 100;
  const TICK_MS = 250;
  const READY_GIVE_UP_MS = 45000;
  const PLAYLIST_URL = /^data:application\/(?:vnd\.apple\.mpegurl|x-mpegurl)((?:;[^,]*)?),/i;
  const apply = Reflect.apply;
  const { defineProperty, getOwnPropertyDescriptor, getPrototypeOf } = Object;
  const { stringify: toJSON, parse: fromJSON } = JSON;
  const { btoa, atob } = window;
  const fromCharCode = String.fromCharCode;
  const Media = HTMLMediaElement.prototype;
  const clock = performance, clockNow = clock.now;
  const now = () => apply(clockNow, clock, []);
  const encoder = new TextEncoder();
  const send = (kind, data) => post(kind, toJSON(data));
  const guard = (fn) => function () { try { return apply(fn, this, arguments); } catch (e) {} };
  // A replacement that looks like the native function to the page (name, length, toString).
  const asNative = (native, call) => new Proxy(native, { apply: (target, self, args) => call(target, self, args) });
  const fire = (el, type) => el.dispatchEvent(new Event(type));
  const bytesOf = (b) =>
    b instanceof ArrayBuffer ? new Uint8Array(b) : ArrayBuffer.isView(b) ? new Uint8Array(b.buffer, b.byteOffset, b.byteLength) : new Uint8Array(0);
  const toBase64 = (bytes) => {
    let text = "";
    for (let i = 0; i < bytes.length; i += 0x8000) text += apply(fromCharCode, null, bytes.subarray(i, i + 0x8000));
    return btoa(text);
  };
  const fromBase64 = (text) => {
    const binary = atob(text);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  };

  let enabled = true;
  let certificate = "";
  let generation = 0;
  let media = null;
  let pending = null;
  let request = null;
  let ticker = 0;
  const tracks = new WeakMap();
  const ownKeys = new WeakSet();
  const keysOf = new WeakMap();
  const everKeyed = new WeakSet();
  let keyed = null;
  const sessionGeneration = new WeakMap();

  // MARK: Key system

  const deliverRequest = () => {
    if (!pending || !request || sessionGeneration.get(pending) !== request.gen) return;
    const target = pending;
    const { message } = request;
    request = null;
    let event;
    try {
      event = new MediaKeyMessageEvent("message", { messageType: "license-request", message });
    } catch (e) {
      event = new Event("message");
      event.messageType = "license-request";
      event.message = message;
    }
    target.dispatchEvent(event);
  };
  const createSession = () => {
    const keySession = new EventTarget();
    keySession.sessionId = "airc-" + Math.random().toString(36).slice(2);
    keySession.expiration = NaN;
    keySession.keyStatuses = new Map();
    let closeSession;
    keySession.closed = new Promise((resolve) => (closeSession = resolve));
    keySession.generateRequest = () => {
      sessionGeneration.set(keySession, generation);
      pending = keySession;
      deliverRequest();
      return Promise.resolve();
    };
    keySession.update = (response) => {
      send("license", { gen: sessionGeneration.get(keySession), ckc: toBase64(bytesOf(response)) });
      keySession.keyStatuses = new Map([[new Uint8Array(16).buffer, "usable"]]);
      keySession.dispatchEvent(new Event("keystatuseschange"));
      return Promise.resolve();
    };
    keySession.load = () => Promise.resolve(false);
    keySession.close = () => { closeSession(); return Promise.resolve(); };
    keySession.remove = () => Promise.resolve();
    return keySession;
  };
  const createKeys = () => {
    const keys = {
      setServerCertificate(server) {
        const bytes = bytesOf(server);
        if (bytes.length) certificate = toBase64(bytes);
        return Promise.resolve(true);
      },
      createSession,
      getStatusForPolicy: () => Promise.resolve("usable"),
    };
    ownKeys.add(keys);
    return keys;
  };

  // Another part (Airc's Widevine probe) may already have put its own function on the navigator itself, which would
  // shadow the prototype's: wrap whichever one the page calls.
  const accessHolder = Object.prototype.hasOwnProperty.call(navigator, "requestMediaKeySystemAccess") ? navigator : Navigator.prototype;
  const requestAccess = accessHolder.requestMediaKeySystemAccess;
  defineProperty(accessHolder, "requestMediaKeySystemAccess", {
    ...getOwnPropertyDescriptor(accessHolder, "requestMediaKeySystemAccess"),
    value: asNative(requestAccess, (target, self, args) => {
      if (!enabled) return apply(target, self, args);
      if (args[0] !== KEY_SYSTEM) {
        // Widevine and PlayReady are refused, so the player picks FairPlay; anything else is Chromium's answer.
        if (!/^com\.(?:widevine|microsoft\.playready)(?:\.|$)/.test(String(args[0]))) return apply(target, self, args);
        if (/widevine/i.test(String(args[0]))) send("widevine", {});
        return Promise.reject(new DOMException("Unsupported keySystem or supportedConfigurations.", "NotSupportedError"));
      }
      const configurations = args[1];
      const configuration = (configurations && configurations[0]) || {};
      send("offered", {});
      return Promise.resolve({ keySystem: KEY_SYSTEM, getConfiguration: () => configuration, createMediaKeys: () => Promise.resolve(createKeys()) });
    }),
  });
  const mediaKeys = getOwnPropertyDescriptor(Media, "mediaKeys");
  if (mediaKeys && mediaKeys.get)
    defineProperty(Media, "mediaKeys", {
      ...mediaKeys,
      get() { return keysOf.has(this) ? keysOf.get(this) : apply(mediaKeys.get, this, []); },
    });
  const setMediaKeys = Media.setMediaKeys;
  if (setMediaKeys)
    Media.setMediaKeys = asNative(setMediaKeys, (target, self, args) => {
      if (ownKeys.has(args[0])) {
        keysOf.set(self, args[0]);
        everKeyed.add(self);
        keyed = self;
        return Promise.resolve();
      }
      keysOf.delete(self);
      return apply(target, self, args);
    });

  // MARK: The element, answered from the native player

  const positionOf = (t) =>
    t.paused || !t.playing ? t.time : Math.min(Number.isNaN(t.duration) ? Infinity : t.duration, t.time + (now() - t.stamp) / 1000);
  const rangesOf = (t) => ({ length: t.ready ? 1 : 0, start: () => 0, end: () => (Number.isNaN(t.duration) ? 0 : t.duration) });
  const stopTicking = () => { if (ticker) clearInterval(ticker); ticker = 0; };
  const startTicking = () => {
    if (ticker) return;
    ticker = setInterval(guard(() => {
      const t = media && tracks.get(media);
      if (t && !t.paused) fire(media, "timeupdate");
      else stopTicking();
    }), TICK_MS);
  };
  const finishSeek = (t, el) => { t.seeking = 0; fire(el, "seeked"); fire(el, "timeupdate"); };
  const drives = (t) => !t.detached && !t.failed;
  const seek = (t, el, value) => {
    const time = +value;
    if (!Number.isFinite(time) || time < 0) return;
    t.time = time;
    t.stamp = now();
    t.ended = false;
    if (!drives(t)) { fire(el, "seeking"); fire(el, "seeked"); fire(el, "timeupdate"); return; }
    const seq = ++t.seeks;
    t.seeking = seq;
    send("seek", { time, seq });
    fire(el, "seeking");
    setTimeout(guard(() => { if (t.seeking === seq) finishSeek(t, el); }), SEEK_GIVE_UP_MS);
  };
  const natives = {};
  const override = (name, get, set) => {
    const native = getOwnPropertyDescriptor(Media, name);
    if (!native || !native.get) return;
    natives[name] = native;
    defineProperty(Media, name, {
      ...native,
      get() { const t = tracks.get(this); return t ? get(t) : apply(native.get, this, []); },
      set: native.set
        ? function (value) { const t = tracks.get(this); if (t && set) set(t, this, value); else apply(native.set, this, [value]); }
        : undefined,
    });
  };
  override("readyState", (t) => t.ready);
  override("networkState", (t) => (t.ready ? 1 : 2));
  override("duration", (t) => t.duration);
  override("paused", (t) => t.paused);
  override("ended", (t) => t.ended);
  override("error", (t) => t.error);
  override("buffered", rangesOf);
  override("seekable", rangesOf);
  override("webkitAudioDecodedByteCount", (t) => (t.ready ? 1 : 0));
  override("currentTime", positionOf, seek);
  override("volume", (t) => t.volume, (t, el, value) => {
    const volume = Math.min(Math.max(+value || 0, 0), 1);
    t.volume = volume;
    if (drives(t)) send("volume", { volume });
    fire(el, "volumechange");
  });
  override("muted", (t) => t.muted, (t, el, value) => {
    t.muted = !!value;
    if (drives(t)) send("muted", { muted: t.muted });
    fire(el, "volumechange");
  });
  const nativeValue = (el, name, fallback) => { try { return apply(natives[name].get, el, []); } catch (e) { return fallback; } };

  Media.play = asNative(Media.play, (target, self, args) => {
    const t = tracks.get(self);
    if (!t) return apply(target, self, args);
    if (t.failed) return Promise.reject(new DOMException("The element has no supported sources.", "NotSupportedError"));
    if (t.detached) {
      attach(self, t);
      if (t.time > 0 || t.seeks) send("seek", { time: t.time, seq: ++t.seeks });
    }
    if (t.paused) {
      if (t.ended) seek(t, self, 0);
      t.paused = false;
      t.ended = false;
      t.stamp = now();
      send("play", {});
      fire(self, "play");
      startTicking();
    }
    return Promise.resolve();
  });
  Media.pause = asNative(Media.pause, (target, self, args) => {
    const t = tracks.get(self);
    if (!t) return apply(target, self, args);
    if (t.paused) return;
    t.time = positionOf(t);
    t.paused = true;
    t.playing = false;
    send("pause", {});
    fire(self, "pause");
  });
  Media.load = asNative(Media.load, (target, self, args) => (tracks.has(self) ? undefined : apply(target, self, args)));

  // MARK: Media Session: what the tray and Now Playing show, and what their buttons call

  const session = navigator.mediaSession;
  const actions = new Map();
  const artworkOf = (md) => {
    const art = md && md.artwork;
    if (!art || !art.length) return "";
    const size = (a) => Math.max(0, ...String(a.sizes || "0x0").split(/\s+/).map((s) => parseInt(s, 10) || 0));
    try { return new URL([...art].sort((a, b) => size(b) - size(a))[0].src, location.href).href; } catch (e) { return ""; }
  };
  const sendMetadata = () => {
    if (!media) return;
    const md = session && session.metadata;
    send("metadata", { title: (md && md.title) || "", artist: (md && md.artist) || "", album: (md && md.album) || "", artwork: artworkOf(md) });
  };
  const sendActions = () => send("actions", { actions: [...actions.keys()] });
  const sessionProto = session && getPrototypeOf(session);
  const metadata = sessionProto && getOwnPropertyDescriptor(sessionProto, "metadata");
  if (metadata && metadata.set)
    defineProperty(sessionProto, "metadata", {
      ...metadata,
      set(value) { apply(metadata.set, this, [value]); guard(sendMetadata)(); },
    });
  if (sessionProto && typeof sessionProto.setActionHandler === "function") {
    const setActionHandler = sessionProto.setActionHandler;
    sessionProto.setActionHandler = asNative(setActionHandler, (target, self, args) => {
      const result = apply(target, self, args);
      guard(() => {
        const name = String(args[0]);
        if (typeof args[1] === "function") actions.set(name, args[1]); else actions.delete(name);
        if (media) sendActions();
      })();
      return result;
    });
  }

  // MARK: The playlist

  const encryptedEvent = (skd) => {
    const event = new Event("encrypted");
    event.initDataType = "cbcs";
    event.initData = encoder.encode(skd);
    return event;
  };
  const bridge = (el, value) => {
    if (!enabled || !el || !(everKeyed.has(el) || clearTest)) return false;
    const url = String(value);
    const head = url.match(PLAYLIST_URL);
    if (!head) return false;
    let playlist;
    try {
      playlist = /;base64/i.test(head[1]) ? atob(url.slice(head[0].length)) : decodeURIComponent(url.slice(head[0].length));
    } catch (e) { return false; }
    const skd = (playlist.match(/URI="(skd:\/\/[^"]+)"/) || [])[1];
    if (!/^#EXTM3U/.test(playlist)) return false;
    if (!clearTest && (!skd || !certificate)) return false;
    const previous = tracks.get(el);
    if (media && media !== el) release(media);
    const t = {
      gen: 0, playlist, cert: certificate, loaded: false, detached: false, ready: 0, time: 0, stamp: now(), duration: NaN,
      paused: true, playing: false, ended: false, error: null, failed: false, seeks: 0, seeking: 0,
      volume: previous ? previous.volume : nativeValue(el, "volume", 1),
      muted: previous ? previous.muted : nativeValue(el, "muted", false),
    };
    tracks.set(el, t);
    stopTicking();
    attach(el, t);
    if (skd) setTimeout(guard(() => { if (tracks.get(el) === t) el.dispatchEvent(encryptedEvent(skd)); }), ENCRYPTED_DELAY_MS);
    return true;
  };
  const parentMedia = (source) => (source.parentElement instanceof HTMLMediaElement ? source.parentElement : null);
  const sourceSrc = getOwnPropertyDescriptor(HTMLSourceElement.prototype, "src");
  defineProperty(HTMLSourceElement.prototype, "src", {
    ...sourceSrc,
    set(value) {
      if (guard(bridge)(parentMedia(this) || keyed, value)) return;
      guard(unbridge)(parentMedia(this));
      apply(sourceSrc.set, this, [value]);
    },
  });
  const mediaSrc = getOwnPropertyDescriptor(Media, "src");
  defineProperty(Media, "src", {
    ...mediaSrc,
    set(value) {
      if (guard(bridge)(this, value)) return;
      guard(unbridge)(this);
      apply(mediaSrc.set, this, [value]);
    },
  });
  const srcObject = getOwnPropertyDescriptor(Media, "srcObject");
  if (srcObject && srcObject.set)
    defineProperty(Media, "srcObject", {
      ...srcObject,
      set(value) { guard(unbridge)(this); apply(srcObject.set, this, [value]); },
    });
  const ElementProto = Element.prototype;
  const isSrc = (name) => typeof name === "string" && name.toLowerCase() === "src";
  defineProperty(Media, "setAttribute", {
    ...getOwnPropertyDescriptor(ElementProto, "setAttribute"),
    value: asNative(ElementProto.setAttribute, (target, self, args) => {
      if (isSrc(args[0])) {
        if (guard(bridge)(self, args[1])) return;
        guard(unbridge)(self);
      }
      return apply(target, self, args);
    }),
  });
  defineProperty(Media, "removeAttribute", {
    ...getOwnPropertyDescriptor(ElementProto, "removeAttribute"),
    value: asNative(ElementProto.removeAttribute, (target, self, args) => {
      if (isSrc(args[0])) guard(unbridge)(self);
      return apply(target, self, args);
    }),
  });

  function attach(el, t) {
    const previousGen = t.gen;
    const gen = ++generation;
    t.gen = gen;
    t.detached = false;
    t.loaded = false;
    if (previousGen && pending && sessionGeneration.get(pending) === previousGen) sessionGeneration.set(pending, gen);
    media = el;
    request = null;
    const { playlist } = t;
    const parts = Math.max(1, Math.ceil(playlist.length / PLAYLIST_PART));
    for (let part = 0; part < parts; part++) {
      const chunk = playlist.slice(part * PLAYLIST_PART, (part + 1) * PLAYLIST_PART);
      send("load", { gen, part, parts, playlist: chunk, cert: part === 0 ? t.cert : null, volume: t.volume, muted: t.muted });
    }
    sendMetadata();
    sendActions();
    setTimeout(guard(() => {
      if (tracks.get(el) === t && t.gen === gen && !t.loaded && !t.detached) {
        send("failed", { gen, step: "player" });
        fail(el, t);
      }
    }), READY_GIVE_UP_MS);
  }
  function release(el) {
    const t = tracks.get(el);
    if (!t) return;
    t.detached = true;
    if (t.paused) return;
    t.time = positionOf(t);
    t.paused = true;
    t.playing = false;
    stopTicking();
    fire(el, "pause");
  }
  function unbridge(el) {
    if (!el || !tracks.has(el)) return;
    tracks.delete(el);
    if (media === el) {
      media = null;
      request = null;
      stopTicking();
      send("stop", {});
    }
    fire(el, "emptied");
  }
  const fail = (el, t) => {
    if (t.failed) return;
    if (media === el && drives(t)) { request = null; send("stop", {}); }
    t.failed = true;
    t.playing = false;
    t.paused = true;
    stopTicking();
    t.error = { code: 3, message: "Protected playback failed", MEDIA_ERR_ABORTED: 1, MEDIA_ERR_NETWORK: 2, MEDIA_ERR_DECODE: 3, MEDIA_ERR_SRC_NOT_SUPPORTED: 4 };
    fire(el, "error");
  };
  const remote = (command, time) => {
    const t = media && tracks.get(media);
    const action = command === "toggle" ? (t && !t.paused ? "pause" : "play") : command;
    const handler = actions.get(action);
    if (handler) return handler(action === "seekto" ? { action, seekTime: time } : { action });
    if (!media) return;
    if (action === "play") media.play();
    else if (action === "pause") media.pause();
    else if (action === "seekto" && Number.isFinite(time)) media.currentTime = time;
  };
  const handle = (m) => {
    if (m.event === "remote") return remote(m.command, m.time);
    const el = media;
    const t = el && tracks.get(el);
    if (!t) return;
    if (m.event === "stolen") return release(el);
    if (m.gen !== t.gen || t.failed) return;
    if (m.event === "request") {
      request = { gen: m.gen, message: fromBase64(m.spc).buffer };
      deliverRequest();
    } else if (m.event === "ready") {
      t.loaded = true;
      t.duration = m.duration;
      t.ready = 4;
      for (const type of ["loadedmetadata", "durationchange", "loadeddata", "canplay", "canplaythrough"]) fire(el, type);
    } else if (m.event === "position") {
      if (m.seq < t.seeks) return;
      t.time = m.time;
      t.stamp = now();
      if (t.seeking) finishSeek(t, el);
      const was = t.playing;
      t.playing = !!m.playing && !t.paused;
      if (t.playing && !was) fire(el, "playing");
      else if (was && !t.playing && !t.paused) fire(el, "waiting");
    } else if (m.event === "ended") {
      if (!Number.isNaN(t.duration)) t.time = t.duration;
      t.playing = false;
      t.paused = true;
      t.ended = true;
      stopTicking();
      fire(el, "timeupdate");
      fire(el, "pause");
      fire(el, "ended");
    } else if (m.event === "failed") {
      fail(el, t);
    }
  };
  addEventListener("pagehide", guard((e) => {
    if (!e.isTrusted || !media) return;
    send("stop", {});
    release(media);
  }));
  return function (kind, json) {
    if (kind === "enabled" && json === "false") { enabled = false; if (media) release(media); return; }
    if (kind !== "event") return;
    let m;
    try { m = fromJSON(json); } catch (e) { return; }
    if (m && typeof m === "object") guard(handle)(m);
  };
}
"""#
}
