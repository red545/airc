// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// Observe only tracks the page sends to a call. Never enumerate devices or request capture. No provider selectors
/// exist in the current call adapters; control stays with the page's registered Media Session action handlers.
enum CallTrackState {
    static let script = #"""
    function(post) {
      if (window.top !== window || !window.RTCPeerConnection) return;
      const watched = new WeakSet(), knownPeers = new WeakSet(), peers = new Set();
      let previous = '';
      function report() {
        const tracks = Array.from(peers).flatMap(ref => {
          const p = ref.deref();
          if (!p || p.signalingState === 'closed') { peers.delete(ref); return []; }
          return p.getSenders().map(s => s.track);
        }).filter(t => t && !(t.getSettings && t.getSettings().displaySurface));
        function on(kind) {
          const list = tracks.filter(t => t.kind === kind);
          return list.length ? list.some(t => t.readyState === 'live' && t.enabled && !t.muted) : null;
        }
        const json = JSON.stringify({mic: on('audio'), cam: on('video')});
        if (json !== previous) { previous = json; post('state', json); }
      }
      function watch(t) {
        if (!t || watched.has(t) || (t.getSettings && t.getSettings().displaySurface)) return;
        watched.add(t);
        ['mute', 'unmute', 'ended'].forEach(e => t.addEventListener(e, report));
        const enabled = Object.getOwnPropertyDescriptor(MediaStreamTrack.prototype, 'enabled');
        if (enabled && enabled.get && enabled.set) {
          try { Object.defineProperty(t, 'enabled', {configurable: true,
            get() { return enabled.get.call(this); },
            set(v) { enabled.set.call(this, v); report(); }}); } catch (_) {}
        }
        const stop = t.stop;
        t.stop = function() { const result = stop.apply(this, arguments); report(); return result; };
        report();
      }
      const proto = RTCPeerConnection.prototype;
      ['addTrack', 'addTransceiver'].forEach(name => {
        const original = proto[name];
        if (!original) return;
        proto[name] = function() {
          const result = original.apply(this, arguments);
          if (!knownPeers.has(this)) { knownPeers.add(this); peers.add(new WeakRef(this)); }
          watch(name === 'addTrack' ? result.track : result.sender.track);
          return result;
        };
      });
      ['removeTrack', 'close'].forEach(name => {
        const original = proto[name];
        proto[name] = function() {
          const result = original.apply(this, arguments);
          report();
          return result;
        };
      });
      const replace = RTCRtpSender.prototype.replaceTrack;
      RTCRtpSender.prototype.replaceTrack = function(t) {
        return replace.call(this, t).then(value => { watch(t); report(); return value; });
      };
      post('state', JSON.stringify({mic: null, cam: null}));
    }
    """#
}
