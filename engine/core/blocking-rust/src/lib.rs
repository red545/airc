// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
//! Shared native filter bridge for Chromium and WebKit integration.
//! C callers own handle lifetime and may not free during a call. No Rust layout
//! crosses the ABI. All text is bounded UTF-8. A malformed request is an error,
//! not a blocking decision. Release panic=abort never unwinds into C++/Swift.
use adblock::{
    Engine, FilterSet,
    lists::{ParseOptions, ParsedLine, RuleTypes},
    request::Request,
};
use std::{ptr, slice, str};

const MAX_LIST_BYTES: usize = 32 * 1024 * 1024;
const MAX_REQUEST_BYTES: usize = 64 * 1024;

pub struct BlockingEngine(Engine);

#[repr(C)]
pub struct Bytes {
    pub data: *mut u8,
    pub len: usize,
}
impl Bytes {
    fn empty() -> Self {
        Self {
            data: ptr::null_mut(),
            len: 0,
        }
    }
    fn from_vec(bytes: Vec<u8>) -> Self {
        if bytes.is_empty() {
            return Self::empty();
        }
        let bytes = bytes.into_boxed_slice();
        let len = bytes.len();
        Self {
            data: Box::into_raw(bytes).cast::<u8>(),
            len,
        }
    }
}

// SAFETY: caller supplies live readable memory for len bytes. Limits prevent
// unbounded inputs; pointer validity is necessarily the C caller's obligation.
unsafe fn text<'a>(data: *const u8, len: usize, limit: usize) -> Option<&'a str> {
    if len > limit {
        return None;
    }
    if len == 0 {
        return Some("");
    }
    if data.is_null() {
        return None;
    }
    str::from_utf8(unsafe { slice::from_raw_parts(data, len) }).ok()
}
fn json(value: &impl serde::Serialize) -> Bytes {
    serde_json::to_vec(value)
        .map(Bytes::from_vec)
        .unwrap_or_else(|_| Bytes::empty())
}

#[unsafe(no_mangle)]
pub extern "C" fn airc_blocking_abi_version() -> u32 {
    1
}

/// # Safety
/// Text pointer must be readable for len bytes. Returns null on invalid input.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn airc_blocking_create(data: *const u8, len: usize) -> *mut BlockingEngine {
    let Some(list) = (unsafe { text(data, len, MAX_LIST_BYTES) }) else {
        return ptr::null_mut();
    };
    let mut filters = FilterSet::new(false);
    filters.add_filter_list(list.to_owned(), ParseOptions::default());
    Box::into_raw(Box::new(BlockingEngine(Engine::new_with_filter_set(
        filters,
    ))))
}

/// # Safety
/// Handle must be null or returned by create, and freed exactly once, with no
/// concurrent calls. Lists are immutable after construction; replace handles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn airc_blocking_destroy(engine: *mut BlockingEngine) {
    if !engine.is_null() {
        drop(unsafe { Box::from_raw(engine) });
    }
}

/// # Safety
/// Buffer must be an unchanged return value from this library, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn airc_blocking_bytes_free(bytes: Bytes) {
    if !bytes.data.is_null() {
        drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(bytes.data, bytes.len)) });
    }
}

/// # Safety
/// Handle must be live. Inputs must be readable, bounded UTF-8. The return value
/// is -1 for invalid input, 0 allowed, 1 blocked. This is a measurement fast path;
/// the integrated caller must also handle rewrite/redirect/CSP (see match_json).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn airc_blocking_check(
    engine: *const BlockingEngine,
    url: *const u8,
    url_len: usize,
    source: *const u8,
    source_len: usize,
    kind: *const u8,
    kind_len: usize,
    method: *const u8,
    method_len: usize,
) -> i32 {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        return -1;
    };
    let Some(url) = (unsafe { text(url, url_len, MAX_REQUEST_BYTES) }) else {
        return -1;
    };
    let Some(source) = (unsafe { text(source, source_len, MAX_REQUEST_BYTES) }) else {
        return -1;
    };
    let Some(kind) = (unsafe { text(kind, kind_len, 64) }) else {
        return -1;
    };
    let Some(method) = (unsafe { text(method, method_len, 32) }) else {
        return -1;
    };
    match Request::new(url, source, kind, method) {
        Ok(request) => i32::from(engine.0.check_network_request(&request).should_block()),
        Err(_) => -1,
    }
}

/// # Safety
/// Handle and all input ranges must be valid for the duration of the call.
/// Returns null/zero on malformed input, otherwise owned JSON. Never logs URLs.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn airc_blocking_match_json(
    engine: *const BlockingEngine,
    url: *const u8,
    url_len: usize,
    source: *const u8,
    source_len: usize,
    kind: *const u8,
    kind_len: usize,
    method: *const u8,
    method_len: usize,
) -> Bytes {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        return Bytes::empty();
    };
    let Some(url) = (unsafe { text(url, url_len, MAX_REQUEST_BYTES) }) else {
        return Bytes::empty();
    };
    let Some(source) = (unsafe { text(source, source_len, MAX_REQUEST_BYTES) }) else {
        return Bytes::empty();
    };
    let Some(kind) = (unsafe { text(kind, kind_len, 64) }) else {
        return Bytes::empty();
    };
    let Some(method) = (unsafe { text(method, method_len, 32) }) else {
        return Bytes::empty();
    };
    let Ok(request) = Request::new(url, source, kind, method) else {
        return Bytes::empty();
    };
    let result = engine.0.check_network_request(&request);
    json(&serde_json::json!({
        "blocked": result.should_block(), "redirect": result.redirect,
        "rewrittenURL": result.rewritten_url, "csp": engine.0.get_csp_directives(&request),
    }))
}

/// Owns both returned buffers. Free each with airc_blocking_bytes_free.
#[repr(C)]
pub struct Decision {
    pub valid: i32,
    pub blocked: i32,
    pub rewritten_url: Bytes,
    pub csp: Bytes,
}
impl Decision {
    fn invalid() -> Self {
        Self {
            valid: 0,
            blocked: 0,
            rewritten_url: Bytes::empty(),
            csp: Bytes::empty(),
        }
    }
}
/// # Safety
/// Handle and UTF-8 input ranges must remain live for the call. Redirect
/// resources are intentionally not loaded; unsupported resources block normally.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn airc_blocking_match(
    engine: *const BlockingEngine,
    url: *const u8,
    url_len: usize,
    source: *const u8,
    source_len: usize,
    kind: *const u8,
    kind_len: usize,
    method: *const u8,
    method_len: usize,
) -> Decision {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        return Decision::invalid();
    };
    let Some(url) = (unsafe { text(url, url_len, MAX_REQUEST_BYTES) }) else {
        return Decision::invalid();
    };
    let Some(source) = (unsafe { text(source, source_len, MAX_REQUEST_BYTES) }) else {
        return Decision::invalid();
    };
    let Some(kind) = (unsafe { text(kind, kind_len, 64) }) else {
        return Decision::invalid();
    };
    let Some(method) = (unsafe { text(method, method_len, 32) }) else {
        return Decision::invalid();
    };
    let Ok(request) = Request::new(url, source, kind, method) else {
        return Decision::invalid();
    };
    let result = engine.0.check_network_request(&request);
    Decision {
        valid: 1,
        blocked: i32::from(result.should_block()),
        rewritten_url: result
            .rewritten_url
            .map(|s| Bytes::from_vec(s.into_bytes()))
            .unwrap_or_else(Bytes::empty),
        csp: engine
            .0
            .get_csp_directives(&request)
            .map(|s| Bytes::from_vec(s.into_bytes()))
            .unwrap_or_else(Bytes::empty),
    }
}

/// # Safety
/// Handle and URL range must be live. Output includes generichide/exceptions,
/// not just selectors. Script/procedural fields are data, never evaluated here.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn airc_blocking_cosmetics(
    engine: *const BlockingEngine,
    url: *const u8,
    len: usize,
) -> Bytes {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        return Bytes::empty();
    };
    let Some(url) = (unsafe { text(url, len, MAX_REQUEST_BYTES) }) else {
        return Bytes::empty();
    };
    json(&engine.0.url_cosmetic_resources(url))
}

/// # Safety
/// Live handle, readable URL and JSON ranges. tokens is {classes:[...],ids:[...]}.
/// The engine derives its own exceptions from URL rather than trusting the page.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn airc_blocking_generic_cosmetics(
    engine: *const BlockingEngine,
    url: *const u8,
    url_len: usize,
    tokens: *const u8,
    tokens_len: usize,
) -> Bytes {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        return Bytes::empty();
    };
    let Some(url) = (unsafe { text(url, url_len, MAX_REQUEST_BYTES) }) else {
        return Bytes::empty();
    };
    let Some(tokens) = (unsafe { text(tokens, tokens_len, MAX_REQUEST_BYTES) }) else {
        return Bytes::empty();
    };
    let Ok(tokens) = serde_json::from_str::<serde_json::Value>(tokens) else {
        return Bytes::empty();
    };
    let Some(classes) = tokens.get("classes").and_then(|v| v.as_array()) else {
        return Bytes::empty();
    };
    let Some(ids) = tokens.get("ids").and_then(|v| v.as_array()) else {
        return Bytes::empty();
    };
    if classes.len() + ids.len() > 4096 || classes.iter().chain(ids).any(|v| !v.is_string()) {
        return Bytes::empty();
    }
    let resources = engine.0.url_cosmetic_resources(url);
    if resources.generichide {
        return json(&Vec::<String>::new());
    }
    json(&engine.0.hidden_class_id_selectors(
        classes.iter().filter_map(|v| v.as_str()),
        ids.iter().filter_map(|v| v.as_str()),
        &resources.exceptions,
    ))
}

/// # Safety
/// Live handle. Serialized data stays local and is version-bound; this probe
/// deliberately does not expose deserialization of untrusted indexed data.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn airc_blocking_serialize(engine: *const BlockingEngine) -> Bytes {
    match unsafe { engine.as_ref() } {
        Some(engine) => Bytes::from_vec(engine.0.serialize()),
        None => Bytes::empty(),
    }
}

/// # Safety
/// Readable list text. Returns rules and counts. The accepted count alone does
/// not cover partial conversions; the probe reports per-rule failures too.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn airc_blocking_webkit(data: *const u8, len: usize) -> Bytes {
    let Some(list) = (unsafe { text(data, len, MAX_LIST_BYTES) }) else {
        return Bytes::empty();
    };
    let mut failures = std::collections::BTreeMap::<String, usize>::new();
    let mut candidates = 0usize;
    let mut cosmetics = 0usize;
    for line in list
        .lines()
        .map(str::trim)
        .filter(|s| !s.is_empty() && !s.starts_with('!') && !s.starts_with('['))
    {
        candidates += 1;
        let failure = match adblock::lists::parse_filter(line, true, ParseOptions::default()) {
            Ok(ParsedLine::Cosmetic(_)) => {
                cosmetics += 1;
                None
            }
            Ok(parsed) => adblock::content_blocking::CbRuleEquivalent::try_from(parsed)
                .err()
                .map(|e| format!("conversion:{e:?}")),
            Err(error) => Some(format!("parse:{error}")),
        };
        if let Some(error) = failure {
            *failures.entry(error).or_default() += 1;
        }
    }
    let mut filters = FilterSet::new(true);
    // All cosmetic rules use the same Rust selector path on both engines.
    // Converting generic CSS into WK rules would bypass generichide and the
    // per-selector exceptions handled by that path.
    filters.add_filter_list(
        list.to_owned(),
        ParseOptions {
            rule_types: RuleTypes::NetworkOnly,
            ..ParseOptions::default()
        },
    );
    match filters.into_content_blocking() {
        Ok((rules, accepted)) => json(
            &serde_json::json!({"rules": rules, "accepted": accepted.len(), "candidates": candidates, "cosmeticsHandledSeparately": cosmetics, "perRuleFailures": failures}),
        ),
        Err(_) => Bytes::empty(),
    }
}

/// # Safety
/// Readable bounded UTF-8 filter text. Returns a JSON rules array directly,
/// avoiding a second Foundation object graph in production. Diagnostics are
/// available through airc_blocking_webkit for conversion reports.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn airc_blocking_webkit_rules(data: *const u8, len: usize) -> Bytes {
    let Some(list) = (unsafe { text(data, len, MAX_LIST_BYTES) }) else {
        return Bytes::empty();
    };
    let mut filters = FilterSet::new(true);
    // All cosmetic rules use the same Rust selector path on both engines.
    // Converting generic CSS into WK rules would bypass generichide and the
    // per-selector exceptions handled by that path.
    filters.add_filter_list(
        list.to_owned(),
        ParseOptions {
            rule_types: RuleTypes::NetworkOnly,
            ..ParseOptions::default()
        },
    );
    match filters.into_content_blocking() {
        Ok((rules, _)) => json(&rules),
        Err(_) => Bytes::empty(),
    }
}

#[cfg(feature = "measure-heap")]
mod heap_probe;
