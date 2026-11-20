// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
//
// The page script below is adapted from the protected-video block of Ardia's page_script.js
// (https://github.com/ardia-browser/ardia, packages/ardiacore/ios/page_script.js), which is Copyright 2026 Mantra Patel,
// licensed under the Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0); modified by The Airc
// Authors: a self-contained page-script part with Airc's message protocol, without the controls copy (a later step),
// the page backdrop measuring or the Media Session matching, and with a test origin.

import Foundation
import AircKit

/// The `fairplayvideo` part (docs/design/fairplay-bridge.md, step 2): on a listed video origin's top frame, offers the
/// page FairPlay through EME, stands in for MediaSource/SourceBuffer on the player's video element, ships the fMP4 init
/// and fragments to the app (FairPlayVideo), and answers the element from the native renderer's reports.
enum FairPlayVideoScript {
    /// `origins`: the video origins it acts on; `anyPathOrigin`: a test origin where any path is a player page (the
    /// services' player routes are /watch/ and /play/).
    static func source(origins: [String], anyPathOrigin: String?, userAgent: String) -> String {
        func json(_ list: [String]) -> String {
            (try? JSONSerialization.data(withJSONObject: list, options: .withoutEscapingSlashes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        return template
            .replacingOccurrences(of: "__AIRC_VIDEO_ORIGINS__", with: json(origins))
            .replacingOccurrences(of: "__AIRC_VIDEO_ANY_PATH__", with: json(anyPathOrigin.map { [$0] } ?? []))
            .replacingOccurrences(of: "__AIRC_SAFARI_UA__", with: json([userAgent]))
    }

    private static let template = #"""
function (post) {
  "use strict";
  var ORIGINS = __AIRC_VIDEO_ORIGINS__, ANY_PATH = __AIRC_VIDEO_ANY_PATH__;
  try {
    if (window !== window.top || ORIGINS.indexOf(location.origin) < 0 || !window.MediaSource) return null;
  } catch (e) { return null; }
  const apply = Reflect.apply;
  const { keys, setPrototypeOf, defineProperty, getOwnPropertyDescriptor, create } = Object;
  const { isArray } = Array;
  const { stringify: toJSON, parse: fromJSON } = JSON;
  const send = (kind, data) => post(kind, toJSON(data));
  const guard = (fn) => function () { try { return apply(fn, this, arguments); } catch (e) {} };
  const asNative = (native, call) => new Proxy(native, { apply: (target, self, args) => call(target, self, args) });
  const raf = window.requestAnimationFrame;
  const SAFARI_UA = __AIRC_SAFARI_UA__[0];
  const PLAYER_ROUTE = ANY_PATH.indexOf(location.origin) >= 0 ? /^\// : location.origin === "https://www.netflix.com" ? /^\/watch\// : /^\/play\//;
  const UNDECODABLE = /av01|vp0?9|dvh1|dvhe|dav1/i;
  const FAIRPLAY = /^com\.apple\.fps/;
  const OTHER_KEY_SYSTEMS = /^com\.(widevine|microsoft|chromecast|youtube)/;
  const PART_BYTES = 45000;
  const MAX_KEY_BYTES = 45000;
  const MAX_PENDING_BYTES = 64e6;
  const MAX_BUFFER_ID = 64;
  const TICK_MS = 250;
  const FRAME_RATE = 24;
  const KEY_WAIT_MS = 15000;
  const AHEAD_LIMIT_S = 1;
  const KEEP_BEHIND_S = 5;
  const VIDEO_QUOTA = 200e6;
  const AUDIO_QUOTA = 24e6;
  const fromCharCode = String.fromCharCode;
  const { btoa, atob } = window;
  const clock = performance;
  const clockNow = clock.now;
  const now = () => apply(clockNow, clock, []);
  const soon = (fn, ms) => setTimeout(guard(fn), ms);
  // The services pick their FairPlay player by browser: the page sees Safari.
  const face = { userAgent: SAFARI_UA, appVersion: SAFARI_UA.slice(8), vendor: "Apple Computer, Inc.", platform: "MacIntel", userAgentData: undefined };
  for (const name of keys(face)) {
    const was = getOwnPropertyDescriptor(Navigator.prototype, name);
    if (was && was.get) defineProperty(Navigator.prototype, name, { ...was, get: asNative(was.get, () => face[name]) });
  }
  try { delete window.chrome; } catch (e) {}

  const mp4 = (() => {
    const fourcc = (u, i) => String.fromCharCode(u[i], u[i + 1], u[i + 2], u[i + 3]);
    const viewOf = (u) => new DataView(u.buffer, u.byteOffset, u.byteLength);
    const boxes = (u, start, end) => {
      const view = viewOf(u);
      const found = [];
      let at = start;
      while (at + 8 <= end) {
        let size = view.getUint32(at);
        let header = 8;
        if (size === 1) {
          if (at + 16 > end) break;
          size = view.getUint32(at + 8) * 4294967296 + view.getUint32(at + 12);
          header = 16;
        } else if (size === 0) size = end - at;
        if (size < header || at + size > end) break;
        found.push({ type: fourcc(u, at + 4), start: at, body: at + header, end: at + size });
        at += size;
      }
      return found;
    };
    const child = (u, box, type) => box && boxes(u, box.body, box.end).find((b) => b.type === type);
    const describeInit = (u) => {
      const view = viewOf(u);
      const info = { timescale: 1, sampleDuration: 0, width: 0, height: 0, duration: 0 };
      const moov = boxes(u, 0, u.length).find((b) => b.type === "moov");
      const trak = child(u, moov, "trak");
      const tkhd = child(u, trak, "tkhd");
      if (tkhd) {
        const at = tkhd.body + (u[tkhd.body] === 1 ? 88 : 76);
        if (at + 8 <= tkhd.end) {
          info.width = view.getUint32(at) >>> 16;
          info.height = view.getUint32(at + 4) >>> 16;
        }
      }
      const mdhd = child(u, child(u, trak, "mdia"), "mdhd");
      if (mdhd) info.timescale = view.getUint32(mdhd.body + (u[mdhd.body] === 1 ? 20 : 12)) || 1;
      const trex = child(u, child(u, moov, "mvex"), "trex");
      if (trex) info.sampleDuration = view.getUint32(trex.body + 12);
      const wideAt = (at) => view.getUint32(at) * 4294967296 + view.getUint32(at + 4);
      const mvhd = child(u, moov, "mvhd");
      if (mvhd && mvhd.body + 32 <= mvhd.end) {
        const wide = u[mvhd.body] === 1;
        const scale = view.getUint32(mvhd.body + (wide ? 20 : 12));
        const whole = wide ? wideAt(mvhd.body + 24) : view.getUint32(mvhd.body + 16);
        const mehd = child(u, child(u, moov, "mvex"), "mehd");
        const fragments = mehd && mehd.body + (u[mehd.body] === 1 ? 12 : 8) <= mehd.end ? (u[mehd.body] === 1 ? wideAt(mehd.body + 4) : view.getUint32(mehd.body + 4)) : 0;
        const unknown = (n) => n === 0xffffffff || n >= Number.MAX_SAFE_INTEGER;
        const longest = Math.max(unknown(whole) ? 0 : whole, unknown(fragments) ? 0 : fragments);
        if (scale && longest) info.duration = longest / scale;
      }
      return info;
    };
    const fragmentTimes = (u, info) => {
      const view = viewOf(u);
      let start = null;
      let duration = 0;
      for (const moof of boxes(u, 0, u.length)) {
        if (moof.type !== "moof") continue;
        const traf = child(u, moof, "traf");
        if (!traf) continue;
        let sampleDuration = info.sampleDuration;
        const tfhd = child(u, traf, "tfhd");
        if (tfhd) {
          const flags = view.getUint32(tfhd.body) & 0xffffff;
          let at = tfhd.body + 8;
          if (flags & 1) at += 8;
          if (flags & 2) at += 4;
          if (flags & 8) sampleDuration = view.getUint32(at);
        }
        const tfdt = child(u, traf, "tfdt");
        if (tfdt && start === null)
          start = u[tfdt.body] === 1 ? view.getUint32(tfdt.body + 4) * 4294967296 + view.getUint32(tfdt.body + 8) : view.getUint32(tfdt.body + 4);
        for (const trun of boxes(u, traf.body, traf.end)) {
          if (trun.type !== "trun") continue;
          const flags = view.getUint32(trun.body) & 0xffffff;
          const count = view.getUint32(trun.body + 4);
          if (!(flags & 0x100)) { duration += count * sampleDuration; continue; }
          let at = trun.body + 8 + (flags & 1 ? 4 : 0) + (flags & 4 ? 4 : 0);
          const stride = 4 + (flags & 0x200 ? 4 : 0) + (flags & 0x400 ? 4 : 0) + (flags & 0x800 ? 4 : 0);
          for (let k = 0; k < count && at + 4 <= trun.end; k++, at += stride) duration += view.getUint32(at);
        }
      }
      return start === null ? null : [start / info.timescale, (start + duration) / info.timescale];
    };
    const split = (u) => {
      const units = [];
      let lead = 0;
      let fragment = false;
      for (const box of boxes(u, 0, u.length)) {
        if (box.type === "moov") {
          units.push({ kind: "init", bytes: u.subarray(lead, box.end) });
          lead = box.end;
          fragment = false;
        } else if (box.type === "moof") {
          fragment = true;
        } else if (box.type === "mdat") {
          if (fragment) units.push({ kind: "segment", bytes: u.subarray(lead, box.end) });
          lead = box.end;
          fragment = false;
        }
      }
      return { units, rest: lead };
    };
    const merged = (segments) => {
      const out = [];
      for (const s of [...segments].sort((a, b) => a.start - b.start)) {
        const last = out[out.length - 1];
        if (last && s.start <= last[1] + 0.25) last[1] = Math.max(last[1], s.end);
        else out.push([s.start, s.end]);
      }
      return out;
    };
    const intersect = (a, b) => {
      const out = [];
      for (let i = 0, j = 0; i < a.length && j < b.length; ) {
        const start = Math.max(a[i][0], b[j][0]);
        const end = Math.min(a[i][1], b[j][1]);
        if (start < end) out.push([start, end]);
        if (a[i][1] < b[j][1]) i++; else j++;
      }
      return out;
    };
    return { boxes, describeInit, fragmentTimes, split, merged, intersect };
  })();

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
  const fire = (target, type) => target.dispatchEvent(new Event(type));
  const fireOwn = (target, type, event = new Event(type)) => {
    target.dispatchEvent(event);
    const handler = target["on" + type];
    if (typeof handler === "function") apply(handler, target, [event]);
  };
  const own = (target, values) => {
    for (const name of keys(values)) defineProperty(target, name, { value: values[name], writable: true, configurable: true, enumerable: true });
    return target;
  };
  const timeRanges = (list) => {
    const out = create(TimeRanges.prototype);
    const at = (i) => {
      if (!(i >= 0 && i < list.length)) throw new DOMException("The index provided is out of range.", "IndexSizeError");
      return list[i];
    };
    defineProperty(out, "length", { value: list.length });
    defineProperty(out, "start", { value: (i) => at(i)[0] });
    defineProperty(out, "end", { value: (i) => at(i)[1] });
    return out;
  };
  const unsupported = () => new DOMException("Unsupported keySystem or supportedConfigurations.", "NotSupportedError");

  // MARK: EME (FairPlay), answered by the app's AVContentKeySession

  const keySessions = new Map();
  const ownKeys = new WeakSet();
  const keysOf = new WeakMap();
  let keySessionSeq = 0;
  const makeKeySession = (keySystem) => {
    const id = ++keySessionSeq;
    const keySession = new EventTarget();
    setPrototypeOf(keySession, MediaKeySession.prototype);
    let closeSession;
    const entry = { keySession, waiting: [] };
    own(keySession, {
      sessionId: "",
      expiration: NaN,
      keyStatuses: new Map(),
      closed: new Promise((resolve) => (closeSession = resolve)),
      onmessage: null,
      onkeystatuseschange: null,
      generateRequest: (initDataType, initData) => {
        const data = bytesOf(initData);
        if (!data.length || data.length > MAX_KEY_BYTES) return Promise.reject(new TypeError("Invalid initData"));
        keySession.sessionId = "airc-" + id;
        send("request", { session: id, keySystem, type: String(initDataType).slice(0, 16), data: toBase64(data) });
        return Promise.resolve();
      },
      update: (response) =>
        new Promise((resolve, reject) => {
          const data = bytesOf(response);
          if (!data.length || data.length > MAX_KEY_BYTES) return reject(new TypeError("Invalid response"));
          const waiter = { resolve, reject };
          entry.waiting.push(waiter);
          soon(() => {
            const at = entry.waiting.indexOf(waiter);
            if (at < 0) return;
            entry.waiting.splice(at, 1);
            resolve();
          }, KEY_WAIT_MS);
          send("update", { session: id, data: toBase64(data) });
        }),
      load: () => Promise.resolve(false),
      remove: () => Promise.resolve(),
      close: () => {
        if (keySessions.delete(id)) send("closeSession", { session: id });
        closeSession();
        return Promise.resolve();
      },
    });
    keySessions.set(id, entry);
    return keySession;
  };
  const makeKeys = (keySystem) => {
    const mediaKeys = own(create(MediaKeys.prototype), {
      setServerCertificate: (certificate) => {
        const data = bytesOf(certificate);
        if (!data.length || data.length > MAX_KEY_BYTES) return Promise.reject(new TypeError("Invalid certificate"));
        send("certificate", { data: toBase64(data) });
        return Promise.resolve(true);
      },
      createSession: () => makeKeySession(keySystem),
      getStatusForPolicy: () => Promise.resolve("usable"),
    });
    ownKeys.add(mediaKeys);
    return mediaKeys;
  };
  const keyAccess = (keySystem, configuration) =>
    own(create(MediaKeySystemAccess.prototype), {
      keySystem,
      getConfiguration: () => configuration,
      createMediaKeys: () => Promise.resolve(makeKeys(keySystem)),
    });
  const pickConfiguration = (configurations) => {
    for (const config of isArray(configurations) ? configurations : []) {
      const asked = isArray(config && config.videoCapabilities) ? config.videoCapabilities : [];
      const video = asked.filter((c) => !UNDECODABLE.test(String((c && c.contentType) || "")));
      if (asked.length && !video.length) continue;
      return {
        label: (config && config.label) || "",
        initDataTypes: isArray(config && config.initDataTypes) ? config.initDataTypes : ["cenc"],
        audioCapabilities: isArray(config && config.audioCapabilities) ? config.audioCapabilities : [],
        videoCapabilities: video,
        distinctiveIdentifier: "not-allowed",
        persistentState: "not-allowed",
        sessionTypes: ["temporary"],
      };
    }
    return null;
  };
  // Airc's Widevine probe may have put its own function on the navigator: wrap whichever one the page calls.
  const accessHolder = Object.prototype.hasOwnProperty.call(navigator, "requestMediaKeySystemAccess") ? navigator : Navigator.prototype;
  const requestAccess = accessHolder.requestMediaKeySystemAccess;
  if (typeof requestAccess === "function")
    defineProperty(accessHolder, "requestMediaKeySystemAccess", {
      ...getOwnPropertyDescriptor(accessHolder, "requestMediaKeySystemAccess"),
      value: asNative(requestAccess, (target, self, args) => {
        const keySystem = String(args[0]);
        if (FAIRPLAY.test(keySystem)) {
          const configuration = pickConfiguration(args[1]);
          send("offered", {});
          return configuration ? Promise.resolve(keyAccess(keySystem, configuration)) : Promise.reject(unsupported());
        }
        if (OTHER_KEY_SYSTEMS.test(keySystem)) {
          if (/widevine/i.test(keySystem)) send("widevine", {});
          return Promise.reject(unsupported());
        }
        return apply(target, self, args);
      }),
    });
  if (!window.WebKitMediaKeys) {
    const WebKitMediaKeys = function WebKitMediaKeys() { throw new TypeError("Illegal constructor"); };
    WebKitMediaKeys.isTypeSupported = (keySystem, type) => FAIRPLAY.test(String(keySystem)) && !UNDECODABLE.test(String(type || ""));
    defineProperty(window, "WebKitMediaKeys", { value: WebKitMediaKeys, writable: true, configurable: true });
  }
  const capabilities = window.MediaCapabilities && MediaCapabilities.prototype;
  if (capabilities && typeof capabilities.decodingInfo === "function")
    capabilities.decodingInfo = asNative(capabilities.decodingInfo, (target, self, args) => {
      const config = args[0] || {};
      const refused = { supported: false, smooth: false, powerEfficient: false, keySystemAccess: null };
      if (config.video && UNDECODABLE.test(String(config.video.contentType || ""))) return Promise.resolve(refused);
      const keySystem = config.keySystemConfiguration && String(config.keySystemConfiguration.keySystem || "");
      if (keySystem && FAIRPLAY.test(keySystem)) {
        const configuration = {
          initDataTypes: [config.keySystemConfiguration.initDataType || "cenc"],
          videoCapabilities: config.video ? [{ contentType: config.video.contentType, robustness: "" }] : [],
          audioCapabilities: config.audio ? [{ contentType: config.audio.contentType, robustness: "" }] : [],
          distinctiveIdentifier: "not-allowed",
          persistentState: "not-allowed",
          sessionTypes: ["temporary"],
        };
        return Promise.resolve({ supported: true, smooth: true, powerEfficient: true, keySystemAccess: keyAccess(keySystem, configuration) });
      }
      if (keySystem) return Promise.resolve(refused);
      return apply(target, self, args);
    });
  const SourceType = window.MediaSource;
  SourceType.isTypeSupported = asNative(SourceType.isTypeSupported, (target, self, args) => !UNDECODABLE.test(String(args[0])) && apply(target, self, args));

  // MARK: The element and its MediaSource, answered by the app's renderers

  const Media = HTMLMediaElement.prototype;
  const Video = HTMLVideoElement.prototype;
  const bridgeOf = new WeakMap();
  const bridgeOfSource = new WeakMap();
  const sourceOfUrl = new Map();
  let bridged = null;
  let held = null;
  let mediaSeq = 0;
  const sendMedia = (b, op, data) => (b.held ? b.backlog.push([op, data]) : send(op, data));
  const bufferedOf = (b) => {
    const live = b.states.filter((st) => !st.removed);
    return live.length ? live.map((st) => mp4.merged(st.segments)).reduce(mp4.intersect) : [];
  };
  const holds = (b, time) => bufferedOf(b).some(([start, end]) => time >= start - 0.1 && time < end);
  const durationOf = (b) => {
    const duration = b.source.duration;
    return Number.isNaN(duration) && b.initDuration > 0 ? b.initDuration : duration;
  };
  const positionOf = (b) => {
    if (b.seeking) return b.seekTo;
    if (b.paused || !b.playing) return b.time;
    const duration = durationOf(b);
    return Math.min(b.time + ((now() - b.stamp) / 1000) * b.rate, b.time + AHEAD_LIMIT_S, Number.isFinite(duration) ? duration : Infinity);
  };
  const sendDuration = (b) => {
    const duration = durationOf(b);
    const known = Number.isFinite(duration) && duration > 0 ? duration : 0;
    if (known === b.sentDuration) return;
    b.sentDuration = known;
    sendMedia(b, "duration", { media: b.id, duration: known });
  };
  const finishSeek = (b) => {
    b.seeking = false;
    b.time = b.seekTo;
    b.stamp = now();
    b.playing = false;
    fire(b.el, "seeked");
    fire(b.el, "timeupdate");
  };
  const progress = (b) => {
    if (bridgeOf.get(b.el) !== b) return;
    sendDuration(b);
    if (!b.metadata && b.states.length && b.states.every((st) => st.info)) {
      b.metadata = true;
      fire(b.el, "durationchange");
      fire(b.el, "loadedmetadata");
      fire(b.el, "resize");
    }
    if (b.seeking && holds(b, b.seekTo)) finishSeek(b);
    if (b.metadata && !b.loaded && holds(b, positionOf(b))) {
      b.loaded = true;
      for (const type of ["loadeddata", "canplay", "canplaythrough"]) fire(b.el, type);
    }
  };
  const stopTicking = (b) => { clearInterval(b.ticker); b.ticker = 0; };
  const tick = (b) => {
    if (bridgeOf.get(b.el) !== b || b.paused) return stopTicking(b);
    const position = positionOf(b);
    if (b.playing) {
      b.frames += Math.max(0, position - b.lastPosition) * FRAME_RATE;
      fire(b.el, "timeupdate");
    }
    b.lastPosition = position;
  };
  const startTicking = (b) => { if (!b.ticker) b.ticker = setInterval(guard(() => tick(b)), TICK_MS); };
  const reportRect = (b) => {
    const r = b.el.getBoundingClientRect();
    const visible = document.visibilityState === "visible" && b.el.isConnected && r.width > 0 && r.height > 0;
    const rect = { media: b.id, x: r.left, y: r.top, width: r.width, height: r.height, scale: devicePixelRatio, visible,
      viewportWidth: innerWidth, viewportHeight: innerHeight };
    const key = [rect.x, rect.y, rect.width, rect.height, rect.scale, visible, innerWidth, innerHeight].join();
    if (key === b.rectKey) return;
    b.rectKey = key;
    sendMedia(b, "rect", rect);
  };
  const watchRect = (b) => {
    const step = guard(() => {
      if (bridgeOf.get(b.el) !== b) return;
      reportRect(b);
      apply(raf, window, [step]);
    });
    apply(raf, window, [step]);
  };
  const release = (el) => {
    const b = bridgeOf.get(el);
    if (!b) return;
    bridgeOf.delete(el);
    bridgeOfSource.delete(b.source);
    stopTicking(b);
    sendMedia(b, "detach", { media: b.id });
    if (held === b) held = null;
    if (bridged === b) {
      bridged = null;
      if (held) takeOver(held);
    }
  };
  const takeOver = (b) => {
    if (held === b) held = null;
    if (bridged && bridged !== b) release(bridged.el);
    b.held = false;
    bridged = b;
    for (const [op, data] of b.backlog.splice(0)) send(op, data);
  };
  const bridge = (el, source) => {
    // A second video the page prepares (the next episode) waits until it plays.
    const hold = !!(bridged && bridged.played && !bridged.ended && bridged.el !== el);
    if (held) release(held.el);
    if (bridged && !hold) release(bridged.el);
    const b = {
      id: ++mediaSeq, el, source, states: [], buffers: [], bufferSeq: 0, paused: true, ended: false, seeking: false,
      seekTo: 0, seekSeq: 0, time: 0, stamp: now(), playing: false, rate: el.playbackRate || 1, metadata: false,
      loaded: false, sourceEnded: false, frames: 0, dropped: 0, lastPosition: 0, error: null, size: [0, 0], rectKey: "",
      ticker: 0, pip: false, pipWindow: null, pipEnter: [], pipExit: [], sentDuration: -1, initDuration: 0,
      played: false, held: hold, backlog: [],
    };
    bridgeOf.set(el, b);
    bridgeOfSource.set(source, b);
    if (hold) held = b; else bridged = b;
    sendMedia(b, "attach", { media: b.id });
    sendMedia(b, "volume", { media: b.id, volume: el.volume, muted: el.muted });
    if (b.rate !== 1) sendMedia(b, "rate", { media: b.id, rate: b.rate });
    sendDuration(b);
    watchRect(b);
  };
  const ship = (b, st, kind, bytes, start, end) => {
    const seq = ++st.seq;
    const parts = Math.max(1, Math.ceil(bytes.length / PART_BYTES));
    for (let part = 0; part < parts; part++)
      sendMedia(b, "append", { media: b.id, buffer: st.id, kind, seq, part, parts, start, end,
        data: toBase64(bytes.subarray(part * PART_BYTES, (part + 1) * PART_BYTES)) });
  };
  const dropRange = (b, st, start, end) => {
    const kept = st.segments.filter((s) => { const middle = (s.start + s.end) / 2; return middle < start || middle >= end; });
    if (kept.length === st.segments.length) return;
    st.segments = kept;
    st.bytes = kept.reduce((sum, s) => sum + s.bytes, 0);
    sendMedia(b, "remove", { media: b.id, buffer: st.id, start, end: Number.isFinite(end) ? end : 1e8 });
  };
  const makeRoom = (b, st, incoming) => {
    const quota = st.video ? VIDEO_QUOTA : AUDIO_QUOTA;
    if (st.bytes + incoming <= quota) return true;
    const before = positionOf(b) - KEEP_BEHIND_S;
    const old = st.segments.filter((s) => s.end < before).sort((x, y) => x.start - y.start);
    if (old.length) dropRange(b, st, -1e6, old[old.length - 1].end);
    return st.bytes + incoming <= quota;
  };
  const take = (b, st, unit) => {
    if (unit.kind === "init") {
      st.info = mp4.describeInit(unit.bytes);
      if (st.info.duration > 0 && !(b.initDuration > 0)) {
        b.initDuration = st.info.duration;
        if (Number.isNaN(b.source.duration)) {
          if (b.metadata) fire(b.el, "durationchange");
          sendDuration(b);
        }
      }
      if (st.video && st.info.width && st.info.height) {
        const changed = b.size[0] !== st.info.width || b.size[1] !== st.info.height;
        b.size = [st.info.width, st.info.height];
        if (changed && b.metadata) fire(b.el, "resize");
      }
      return ship(b, st, "init", unit.bytes, 0, 0);
    }
    if (!st.info) return;
    const times = mp4.fragmentTimes(unit.bytes, st.info);
    if (!times) return;
    const start = times[0] + st.offset;
    const end = Math.max(times[1] + st.offset, start + 0.001);
    if (end <= st.windowStart || start >= st.windowEnd) return;
    st.segments = st.segments.filter((s) => !(start < s.end - 0.05 && end > s.start + 0.05));
    st.segments.push({ start, end, bytes: unit.bytes.length });
    st.bytes = st.segments.reduce((sum, s) => sum + s.bytes, 0);
    ship(b, st, "segment", unit.bytes, start, end);
  };
  const sourceBufferList = (items) => {
    const out = new EventTarget();
    setPrototypeOf(out, SourceBufferList.prototype);
    defineProperty(out, "length", { value: items.length });
    items.forEach((item, i) => defineProperty(out, i, { value: item, enumerable: true }));
    defineProperty(out, Symbol.iterator, { value: () => items[Symbol.iterator]() });
    return out;
  };
  const makeBuffer = (b, mime) => {
    const sb = new EventTarget();
    setPrototypeOf(sb, SourceBuffer.prototype);
    const st = { id: ++b.bufferSeq, video: /^video\//i.test(mime), info: null, pending: new Uint8Array(0), segments: [], bytes: 0,
      updating: false, offset: 0, windowStart: 0, windowEnd: Infinity, mode: "segments", seq: 0, op: 0, removed: false };
    const property = (name, descriptor) => defineProperty(sb, name, { configurable: true, enumerable: true, ...descriptor });
    const busy = () => new DOMException("This SourceBuffer is still processing an 'appendBuffer' or 'remove' operation.", "InvalidStateError");
    const gone = () => new DOMException("This SourceBuffer has been removed from the parent media source.", "InvalidStateError");
    const finish = () => { st.updating = false; fireOwn(sb, "update"); fireOwn(sb, "updateend"); progress(b); };
    property("updating", { get: () => st.updating });
    property("buffered", { get: () => timeRanges(mp4.merged(st.segments)) });
    property("timestampOffset", { get: () => st.offset, set: (v) => (st.offset = Number(v) || 0) });
    property("appendWindowStart", { get: () => st.windowStart, set: (v) => (st.windowStart = Number(v) || 0) });
    property("appendWindowEnd", { get: () => st.windowEnd, set: (v) => (st.windowEnd = Number(v)) });
    property("mode", { get: () => st.mode, set: (v) => (st.mode = String(v)) });
    for (const handler of ["onupdatestart", "onupdate", "onupdateend", "onerror", "onabort"]) property(handler, { value: null, writable: true });
    property("appendBuffer", {
      value: (data) => {
        if (st.removed) throw gone();
        if (st.updating) throw busy();
        const incoming = bytesOf(data);
        if (!makeRoom(b, st, incoming.length))
          throw new DOMException("The SourceBuffer is full, and cannot free space to append additional buffers.", "QuotaExceededError");
        const combined = new Uint8Array(st.pending.length + incoming.length);
        combined.set(st.pending);
        combined.set(incoming, st.pending.length);
        st.updating = true;
        const op = ++st.op;
        if (b.sourceEnded) {
          b.sourceEnded = false;
          sendMedia(b, "end", { media: b.id, ended: false });
          fire(b.source, "sourceopen");
        }
        soon(() => {
          if (st.op !== op || !st.updating) return;
          fireOwn(sb, "updatestart");
          const { units, rest } = mp4.split(combined);
          st.pending = combined.length - rest > MAX_PENDING_BYTES ? new Uint8Array(0) : combined.slice(rest);
          if (bridgeOf.get(b.el) === b) for (const unit of units) take(b, st, unit);
          finish();
        }, 0);
      },
    });
    property("remove", {
      value: (start, end) => {
        if (st.removed) throw gone();
        if (st.updating) throw busy();
        st.updating = true;
        const op = ++st.op;
        soon(() => {
          if (st.op !== op || !st.updating) return;
          fireOwn(sb, "updatestart");
          dropRange(b, st, Number(start), Number(end));
          finish();
        }, 0);
      },
    });
    property("abort", {
      value: () => {
        st.pending = new Uint8Array(0);
        st.op++;
        if (!st.updating) return;
        st.updating = false;
        fireOwn(sb, "abort");
        fireOwn(sb, "updateend");
      },
    });
    property("changeType", {
      value: (type) => {
        if (UNDECODABLE.test(String(type))) throw new DOMException("The type provided ('" + type + "') is unsupported.", "NotSupportedError");
        st.video = /^video\//i.test(String(type));
        sendMedia(b, "buffer", { media: b.id, buffer: st.id, mime: String(type).slice(0, 200) });
      },
    });
    b.states.push(st);
    b.buffers.push(sb);
    sendMedia(b, "buffer", { media: b.id, buffer: st.id, mime: mime.slice(0, 200) });
    return { sb, st };
  };

  const SourceProto = SourceType.prototype;
  SourceProto.addSourceBuffer = asNative(SourceProto.addSourceBuffer, (target, self, args) => {
    const type = String(args[0]);
    if (UNDECODABLE.test(type)) throw new DOMException("The type provided ('" + type + "') is unsupported.", "NotSupportedError");
    const b = bridgeOfSource.get(self);
    if (!b || b.states.length >= 8) return apply(target, self, args);
    if (b.bufferSeq >= MAX_BUFFER_ID) throw new DOMException("This MediaSource has reached the limit of SourceBuffer objects it can handle.", "QuotaExceededError");
    return makeBuffer(b, type).sb;
  });
  SourceProto.removeSourceBuffer = asNative(SourceProto.removeSourceBuffer, (target, self, args) => {
    const b = bridgeOfSource.get(self);
    const at = b ? b.buffers.indexOf(args[0]) : -1;
    if (at < 0) return apply(target, self, args);
    const st = b.states[at];
    st.removed = true;
    st.op++;
    st.updating = false;
    b.buffers.splice(at, 1);
    b.states.splice(at, 1);
    sendMedia(b, "dropBuffer", { media: b.id, buffer: st.id });
  });
  const sourceGetter = (name, read) => {
    const was = getOwnPropertyDescriptor(SourceProto, name);
    if (was && was.get)
      defineProperty(SourceProto, name, {
        ...was,
        get: asNative(was.get, (target, self, args) => {
          const b = bridgeOfSource.get(self);
          return b ? read(b, () => apply(target, self, args)) : apply(target, self, args);
        }),
      });
  };
  sourceGetter("sourceBuffers", (b) => sourceBufferList(b.buffers));
  sourceGetter("activeSourceBuffers", (b) => sourceBufferList(b.buffers));
  sourceGetter("readyState", (b, real) => (b.sourceEnded ? "ended" : real()));
  SourceProto.endOfStream = asNative(SourceProto.endOfStream, (target, self, args) => {
    const b = bridgeOfSource.get(self);
    if (!b) return apply(target, self, args);
    if (args[0]) return;
    b.sourceEnded = true;
    sendMedia(b, "end", { media: b.id, ended: true });
    sendDuration(b);
    fire(self, "sourceended");
  });
  const sourceDuration = getOwnPropertyDescriptor(SourceProto, "duration");
  if (sourceDuration && sourceDuration.set)
    defineProperty(SourceProto, "duration", {
      ...sourceDuration,
      set: asNative(sourceDuration.set, (target, self, args) => {
        const result = apply(target, self, args);
        const b = bridgeOfSource.get(self);
        if (b && bridgeOf.get(b.el) === b) sendDuration(b);
        return result;
      }),
    });
  const createObjectURL = URL.createObjectURL;
  URL.createObjectURL = asNative(createObjectURL, (target, self, args) => {
    const url = apply(target, self, args);
    if (args[0] instanceof SourceType) {
      sourceOfUrl.set(url, args[0]);
      if (sourceOfUrl.size > 32) sourceOfUrl.delete(sourceOfUrl.keys().next().value);
    }
    return url;
  });

  const getter = (proto, name, read) => {
    const was = getOwnPropertyDescriptor(proto, name);
    if (!was || !was.get) return;
    defineProperty(proto, name, {
      ...was,
      get: asNative(was.get, (target, self, args) => {
        const b = bridgeOf.get(self);
        return b ? read(b, self) : apply(target, self, args);
      }),
    });
  };
  const setter = (proto, name, write) => {
    const was = getOwnPropertyDescriptor(proto, name);
    if (!was || !was.set) return;
    defineProperty(proto, name, {
      ...was,
      set: asNative(was.set, (target, self, args) => {
        const b = bridgeOf.get(self);
        return b ? write(b, self, args[0], () => apply(target, self, args)) : apply(target, self, args);
      }),
    });
  };
  const method = (proto, name, call) => {
    const was = proto[name];
    if (typeof was !== "function") return;
    proto[name] = asNative(was, (target, self, args) => {
      const b = bridgeOf.get(self);
      return b ? call(b, self, args, () => apply(target, self, args)) : apply(target, self, args);
    });
  };
  const srcDescriptor = getOwnPropertyDescriptor(Media, "src");
  defineProperty(Media, "src", {
    ...srcDescriptor,
    set: asNative(srcDescriptor.set, (target, self, args) => {
      release(self);
      const result = apply(target, self, args);
      const source = sourceOfUrl.get(String(args[0]));
      if (source && self instanceof HTMLVideoElement && PLAYER_ROUTE.test(location.pathname)) bridge(self, source);
      return result;
    }),
  });
  method(Media, "load", (b, el, args, real) => { release(el); return real(); });
  getter(Media, "currentTime", (b) => positionOf(b));
  setter(Media, "currentTime", (b, el, value) => {
    const time = Number(value);
    if (!Number.isFinite(time)) throw new TypeError("Failed to set the 'currentTime' property on 'HTMLMediaElement': The provided double value is non-finite.");
    const duration = durationOf(b);
    const target = Math.max(0, Number.isFinite(duration) ? Math.min(time, duration) : time);
    b.seekSeq++;
    b.ended = false;
    sendMedia(b, "seek", { media: b.id, time: target, seq: b.seekSeq });
    if (!b.metadata) { b.time = target; b.stamp = now(); return; }
    b.seekTo = target;
    b.seeking = true;
    soon(() => {
      if (!b.seeking || b.seekTo !== target) return;
      fire(el, "seeking");
      progress(b);
    }, 0);
  });
  getter(Media, "paused", (b) => b.paused);
  getter(Media, "ended", (b) => b.ended);
  getter(Media, "seeking", (b) => b.seeking);
  getter(Media, "readyState", (b) => (b.metadata ? (holds(b, positionOf(b)) ? 4 : 1) : 0));
  getter(Media, "buffered", (b) => timeRanges(bufferedOf(b)));
  getter(Media, "seekable", (b) => (Number.isFinite(durationOf(b)) ? timeRanges([[0, durationOf(b)]]) : timeRanges(bufferedOf(b))));
  getter(Media, "duration", (b) => durationOf(b));
  getter(Media, "error", (b) => b.error);
  getter(Video, "videoWidth", (b) => b.size[0]);
  getter(Video, "videoHeight", (b) => b.size[1]);
  getter(Video, "webkitDecodedFrameCount", (b) => Math.floor(b.frames));
  const droppedOf = (b) => Math.min(Math.floor(b.dropped), Math.floor(b.frames));
  getter(Video, "webkitDroppedFrameCount", droppedOf);
  method(Video, "getVideoPlaybackQuality", (b) =>
    own(create(VideoPlaybackQuality.prototype), { creationTime: now(), totalVideoFrames: Math.floor(b.frames), droppedVideoFrames: droppedOf(b), corruptedVideoFrames: 0 })
  );
  const fireSoon = (b, el, types) => soon(() => { if (bridgeOf.get(el) === b) for (const type of types) fire(el, type); }, 0);
  method(Media, "play", (b, el) => {
    if (b.error) return Promise.reject(new DOMException("The element has no supported sources.", "NotSupportedError"));
    b.played = true;
    if (b.held) takeOver(b);
    if (b.paused) {
      b.paused = false;
      b.stamp = now();
      b.lastPosition = positionOf(b);
      fireSoon(b, el, ["play"]);
      sendMedia(b, "play", { media: b.id });
    }
    startTicking(b);
    return Promise.resolve();
  });
  method(Media, "pause", (b, el) => {
    if (b.paused) return;
    b.time = positionOf(b);
    b.paused = true;
    b.playing = false;
    sendMedia(b, "pause", { media: b.id });
    fireSoon(b, el, ["timeupdate", "pause"]);
  });
  setter(Media, "volume", (b, el, value, real) => { real(); sendMedia(b, "volume", { media: b.id, volume: el.volume, muted: el.muted }); });
  setter(Media, "muted", (b, el, value, real) => { real(); sendMedia(b, "volume", { media: b.id, volume: el.volume, muted: el.muted }); });
  setter(Media, "playbackRate", (b, el, value, real) => {
    real();
    b.time = positionOf(b);
    b.stamp = now();
    b.rate = el.playbackRate || 1;
    sendMedia(b, "rate", { media: b.id, rate: b.rate });
  });
  const pictureInPictureWindow = (b) => {
    const out = new EventTarget();
    if (window.PictureInPictureWindow) setPrototypeOf(out, PictureInPictureWindow.prototype);
    return own(out, { width: b.size[0], height: b.size[1], onresize: null });
  };
  const pictureInPictureEvent = (type, pipWindow) => {
    try { return new PictureInPictureEvent(type, { bubbles: true, pictureInPictureWindow: pipWindow }); }
    catch (e) { return own(new Event(type, { bubbles: true }), { pictureInPictureWindow: pipWindow }); }
  };
  method(Video, "requestPictureInPicture", (b) => {
    if (b.pip) return Promise.resolve(b.pipWindow);
    return new Promise((resolve, reject) => {
      b.pipEnter.push({ resolve, reject });
      sendMedia(b, "pip", { media: b.id, enter: true });
    });
  });
  const documentPip = getOwnPropertyDescriptor(Document.prototype, "pictureInPictureElement");
  if (documentPip && documentPip.get)
    defineProperty(Document.prototype, "pictureInPictureElement", {
      ...documentPip,
      get: asNative(documentPip.get, (target, self, args) => {
        if (!bridged || !bridged.pip || self !== document) return apply(target, self, args);
        let el = bridged.el;
        while (el.getRootNode() !== document && el.getRootNode().host) el = el.getRootNode().host;
        return el;
      }),
    });
  const exitPip = Document.prototype.exitPictureInPicture;
  if (typeof exitPip === "function")
    Document.prototype.exitPictureInPicture = asNative(exitPip, (target, self, args) => {
      const b = bridged;
      if (!b || !b.pip || self !== document) return apply(target, self, args);
      return new Promise((resolve) => {
        b.pipExit.push(resolve);
        sendMedia(b, "pip", { media: b.id, enter: false });
      });
    });
  const pipChanged = (b, active) => {
    if (active && !b.pip) {
      b.pip = true;
      b.pipWindow = pictureInPictureWindow(b);
      for (const waiter of b.pipEnter.splice(0)) waiter.resolve(b.pipWindow);
      b.el.dispatchEvent(pictureInPictureEvent("enterpictureinpicture", b.pipWindow));
    } else if (!active) {
      for (const waiter of b.pipEnter.splice(0)) waiter.reject(new DOMException("Picture-in-Picture could not start.", "NotAllowedError"));
      for (const resolve of b.pipExit.splice(0)) resolve();
      if (b.pip) {
        b.pip = false;
        b.el.dispatchEvent(pictureInPictureEvent("leavepictureinpicture", b.pipWindow));
      }
    }
  };
  const mediaKeysDescriptor = getOwnPropertyDescriptor(Media, "mediaKeys");
  if (mediaKeysDescriptor && mediaKeysDescriptor.get)
    defineProperty(Media, "mediaKeys", {
      ...mediaKeysDescriptor,
      get: asNative(mediaKeysDescriptor.get, (target, self, args) => (keysOf.has(self) ? keysOf.get(self) : apply(target, self, args))),
    });
  if (typeof Media.setMediaKeys === "function")
    Media.setMediaKeys = asNative(Media.setMediaKeys, (target, self, args) => {
      const mediaKeys = args[0];
      if (mediaKeys && ownKeys.has(mediaKeys)) { keysOf.set(self, mediaKeys); return Promise.resolve(); }
      keysOf.delete(self);
      return apply(target, self, args);
    });

  const onKeys = (m) => {
    const entry = keySessions.get(m.session);
    if (!entry) return;
    if (m.event === "message") {
      const message = fromBase64(String(m.data || "")).buffer;
      let event;
      try { event = new MediaKeyMessageEvent("message", { messageType: "license-request", message }); }
      catch (e) { event = own(new Event("message"), { messageType: "license-request", message }); }
      return fireOwn(entry.keySession, "message", event);
    }
    const waiting = entry.waiting.splice(0);
    if (m.ok !== true) {
      for (const waiter of waiting) waiter.reject(new DOMException("The key system rejected the licence.", "InvalidStateError"));
      return;
    }
    const statuses = new Map(entry.keySession.keyStatuses);
    for (const id of isArray(m.keyIDs) ? m.keyIDs : []) statuses.set(fromBase64(String(id)).buffer, "usable");
    entry.keySession.keyStatuses = statuses;
    for (const waiter of waiting) waiter.resolve();
    fireOwn(entry.keySession, "keystatuseschange");
  };
  const handle = (m) => {
    if (m.event === "message" || m.event === "keys") return onKeys(m);
    const b = bridged;
    if (!b || m.media !== b.id) return;
    if (m.event === "time") {
      if (m.seq !== b.seekSeq || b.seeking || !Number.isFinite(m.time)) return;
      b.time = m.time;
      b.stamp = now();
      if (Number.isFinite(m.dropped) && m.dropped >= b.dropped) b.dropped = m.dropped;
      const playing = m.playing === true && !b.paused;
      if (playing && !b.playing) {
        b.playing = true;
        b.lastPosition = b.time;
        fire(b.el, "playing");
      } else if (!playing && b.playing) {
        b.playing = false;
        if (!b.paused) fire(b.el, "waiting");
      }
    } else if (m.event === "remote") {
      if (m.command === "play") b.el.play();
      else if (m.command === "pause") b.el.pause();
      else if (m.command === "seekto" && Number.isFinite(m.time) && b.metadata) b.el.currentTime = m.time;
    } else if (m.event === "ended") {
      const duration = durationOf(b);
      b.time = Number.isFinite(duration) ? duration : positionOf(b);
      b.playing = false;
      b.ended = true;
      fire(b.el, "timeupdate");
      if (!b.paused) { b.paused = true; fire(b.el, "pause"); }
      fire(b.el, "ended");
    } else if (m.event === "encrypted") {
      const initData = fromBase64(String(m.data || "")).buffer;
      let event;
      try { event = new MediaEncryptedEvent("encrypted", { initDataType: String(m.type), initData }); }
      catch (e) { event = own(new Event("encrypted"), { initDataType: String(m.type), initData }); }
      fireOwn(b.el, "encrypted", event);
    } else if (m.event === "pip") {
      pipChanged(b, m.active === true);
    } else if (m.event === "seekBy") {
      if (typeof m.delta === "number" && Number.isFinite(m.delta) && b.metadata) b.el.currentTime = positionOf(b) + m.delta;
    } else if (m.event === "failed") {
      b.error = own(create(MediaError.prototype), { code: 3, message: "Protected playback failed" });
      b.paused = true;
      b.playing = false;
      stopTicking(b);
      fire(b.el, "error");
    }
  };
  addEventListener("visibilitychange", guard(() => { if (bridged) reportRect(bridged); }));
  addEventListener("pagehide", guard((e) => { if (e.isTrusted && bridged) release(bridged.el); }));
  return function (kind, json) {
    if (kind !== "event") return;
    let m;
    try { m = fromJSON(json); } catch (e) { return; }
    if (m && typeof m === "object") guard(handle)(m);
  };
}
"""#
}
