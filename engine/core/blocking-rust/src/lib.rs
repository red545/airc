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

pub struct BlockingEngine {
    engine: Engine,
    /// ganalytics: a top-level document the person opens is blocked only by a rule that asks for documents
    /// (`$document`, `$doc`, `$all`), as in Brave and uBlock Origin; this engine holds just those rules plus every
    /// exception. adblock-rust applies any rule without a type to documents too, so `||sentrymagic.com^` or
    /// `||sentry.io^$third-party` showed "blocked by Airc" for the site itself. Subresources and frames use `engine`.
    documents: Engine,
}

/// Whether a network rule names documents among its options. adblock-rust's parsed mask can't tell: a rule without a
/// type gets FROM_DOCUMENT as well.
fn names_documents(line: &str) -> bool {
    let rule = line.strip_prefix("@@").unwrap_or(line);
    let Some(at) = rule.rfind('$') else { return false };
    // A regex rule's own `$` (end anchor) is followed by its closing slash.
    if rule.starts_with('/') && rule[at..].contains('/') {
        return false;
    }
    rule[at + 1..].split(',').any(|option| {
        let name = option.trim().split('=').next().unwrap_or("").to_ascii_lowercase();
        matches!(name.as_str(), "document" | "doc" | "all")
    })
}

/// The document engine's list: rules that name documents, and all exceptions (which also apply to documents).
fn document_rules(list: &str) -> String {
    let mut out = String::new();
    for line in list.lines().map(str::trim) {
        if line.starts_with("@@") || (!line.starts_with('!') && names_documents(line)) {
            out.push_str(line);
            out.push('\n');
        }
    }
    out
}

/// WebKit: adblock-rust ends a conversion with "ignore previous rules for first-party documents", which exempts a
/// top-level page from every rule, `$document` ones included. The rules that name documents (and the exceptions) are
/// added again after it, for the top frame only: the same decision as the Chromium path. Frames are unchanged.
fn with_document_rules(rules: Vec<adblock::content_blocking::CbRule>, list: &str) -> serde_json::Value {
    use adblock::content_blocking::{CbType, ignore_previous_fp_documents};
    let mut out = serde_json::to_value(&rules).unwrap_or_else(|_| serde_json::Value::Array(Vec::new()));
    let mut set = FilterSet::new(true);
    set.add_filter_list(
        document_rules(list),
        ParseOptions { rule_types: RuleTypes::NetworkOnly, ..ParseOptions::default() },
    );
    let Ok((extra, _)) = set.into_content_blocking() else { return out };
    if !extra.iter().any(|rule| rule.action.typ == CbType::Block) {
        return out;
    }
    let exemption = ignore_previous_fp_documents();
    let Some(array) = out.as_array_mut() else { return out };
    for rule in extra.into_iter().filter(|rule| *rule != exemption) {
        let block = rule.action.typ == CbType::Block;
        let Ok(mut value) = serde_json::to_value(&rule) else { continue };
        if block {
            // adblock-rust converts `$document` to an empty resource-type list, which WebKit matches against nothing.
            value["trigger"]["resource-type"] = serde_json::json!(["document"]);
            value["trigger"]["load-context"] = serde_json::json!(["top-frame"]);
        }
        array.push(value);
    }
    out
}

fn is_document(kind: &str) -> bool {
    matches!(kind, "document" | "main_frame")
}

impl BlockingEngine {
    /// (blocked, redirect, rewritten URL) for one request.
    fn decide(&self, request: &Request, kind: &str) -> (bool, Option<String>, Option<String>) {
        let full = self.engine.check_network_request(request);
        if !is_document(kind) {
            return (full.should_block(), full.redirect, full.rewritten_url);
        }
        // A blocked document's result carries no rewrite; an allowed one keeps the full lists' $removeparam.
        let documents = self.documents.check_network_request(request);
        (documents.should_block(), documents.redirect, full.rewritten_url)
    }
}

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
    if !list.trim().is_empty() {
        filters.add_filter_list(
            "youtube.com,youtube-nocookie.com##+js(airc-video-prune)\nyoutube.com,youtube-nocookie.com##ytd-ad-slot-renderer,ytd-display-ad-renderer,ytd-promoted-sparkles-web-renderer,ytd-promoted-video-renderer,ytd-search-pyv-renderer,#masthead-ad".to_owned(),
            ParseOptions::default(),
        );
    }
    let mut engine = Engine::new_with_filter_set(filters);
    let mut document_filters = FilterSet::new(false);
    document_filters.add_filter_list(
        document_rules(list),
        ParseOptions { rule_types: RuleTypes::NetworkOnly, ..ParseOptions::default() },
    );
    let documents = Engine::new_with_filter_set(document_filters);
    let Ok(resources) = serde_json::from_str::<Vec<adblock::resources::Resource>>(
        include_str!("video_ads_resource.json"),
    ) else { return ptr::null_mut(); };
    engine.use_resources(resources);
    Box::into_raw(Box::new(BlockingEngine { engine, documents }))
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
        Ok(request) => i32::from(engine.decide(&request, kind).0),
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
    let (blocked, redirect, rewritten) = engine.decide(&request, kind);
    json(&serde_json::json!({
        "blocked": blocked, "redirect": redirect,
        "rewrittenURL": rewritten, "csp": engine.engine.get_csp_directives(&request),
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
    let (blocked, _, rewritten) = engine.decide(&request, kind);
    Decision {
        valid: 1,
        blocked: i32::from(blocked),
        rewritten_url: rewritten
            .map(|s| Bytes::from_vec(s.into_bytes()))
            .unwrap_or_else(Bytes::empty),
        csp: engine
            .engine
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
    json(&engine.engine.url_cosmetic_resources(url))
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
    let resources = engine.engine.url_cosmetic_resources(url);
    if resources.generichide {
        return json(&Vec::<String>::new());
    }
    json(&engine.engine.hidden_class_id_selectors(
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
        Some(engine) => Bytes::from_vec(engine.engine.serialize()),
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
            &serde_json::json!({"rules": with_document_rules(rules, list), "accepted": accepted.len(), "candidates": candidates, "cosmeticsHandledSeparately": cosmetics, "perRuleFailures": failures}),
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
        Ok((rules, _)) => json(&with_document_rules(rules, list)),
        Err(_) => Bytes::empty(),
    }
}

#[cfg(feature = "measure-heap")]
mod heap_probe;

#[cfg(test)]
mod video_tests {
    use super::*;
    fn script(list: &str, url: &str) -> String {
        unsafe {
            let engine = airc_blocking_create(list.as_ptr(), list.len());
            assert!(!engine.is_null(), "bundled resource decodes");
            let output = airc_blocking_cosmetics(engine, url.as_ptr(), url.len());
            let value: serde_json::Value = serde_json::from_slice(slice::from_raw_parts(output.data, output.len)).unwrap();
            airc_blocking_bytes_free(output);
            airc_blocking_destroy(engine);
            value["injected_script"].as_str().unwrap().to_owned()
        }
    }
    #[test]
    fn video_resource_selection_and_exceptions() {
        assert!(script("", "https://www.youtube.com/watch?v=fixture").is_empty());
        assert!(script("! fixture", "https://www.youtube.com/watch?v=fixture").contains("ytInitialPlayerResponse"));
        assert!(script("! fixture", "https://youtube.com.evil.test/").is_empty());
        assert!(script("! fixture", "https://example.test/").is_empty());
        assert!(script("youtube.com#@#+js(airc-video-prune)", "https://www.youtube.com/").is_empty());
        assert!(script("! fixture", "https://www.youtube-nocookie.com/embed/fixture").contains("ytInitialPlayerResponse"));
    }
}

#[cfg(test)]
mod document_tests {
    use super::*;
    const LIST: &str = "||plain.example^\n||party.example^$third-party\n||page.example^$document\n/landing/*$doc\n\
        ||all.example^$all\n@@||page.example/ok^$document\n||script.example^$script";
    fn blocked(url: &str, source: &str, kind: &str) -> bool {
        unsafe {
            let engine = airc_blocking_create(LIST.as_ptr(), LIST.len());
            assert!(!engine.is_null());
            let d = airc_blocking_match(engine, url.as_ptr(), url.len(), source.as_ptr(), source.len(),
                kind.as_ptr(), kind.len(), "GET".as_ptr(), 3);
            assert_eq!(d.valid, 1);
            airc_blocking_bytes_free(d.rewritten_url);
            airc_blocking_bytes_free(d.csp);
            airc_blocking_destroy(engine);
            d.blocked == 1
        }
    }
    #[test]
    fn options_that_name_documents() {
        assert!(names_documents("||a.example^$document") && names_documents("/x/*$doc,important"));
        assert!(names_documents("||a.example^$all") && names_documents("@@||a.example^$document"));
        assert!(!names_documents("||a.example^") && !names_documents("||a.example^$third-party,script"));
        assert!(!names_documents("||a.example^$~document") && !names_documents("/doc$/"));
    }
    #[test]
    fn top_level_documents_only_by_document_rules() {
        // A page the person opens: plain and party rules don't block it, with or without a source.
        assert!(!blocked("https://plain.example/", "https://plain.example/", "document"));
        assert!(!blocked("https://plain.example/", "", "document"));
        assert!(!blocked("https://party.example/", "https://other.example/", "document"));
        // Rules that name documents do; their exceptions still apply.
        assert!(blocked("https://page.example/", "", "document"));
        assert!(blocked("https://www.other.example/landing/1", "", "document"));
        assert!(blocked("https://all.example/", "", "document"));
        assert!(!blocked("https://page.example/ok", "", "document"));
        // Everything else is unchanged: subresources and frames from other sites stay blocked.
        assert!(blocked("https://plain.example/sdk.js", "https://other.example/", "script"));
        assert!(blocked("https://party.example/sdk.js", "https://other.example/", "script"));
        assert!(blocked("https://plain.example/", "https://other.example/", "subdocument"));
        assert!(blocked("https://script.example/a.js", "https://other.example/", "script"));
    }
    #[test]
    fn webkit_rules_readd_document_rules_after_the_exemption() {
        let rules: serde_json::Value = unsafe {
            let out = airc_blocking_webkit_rules(LIST.as_ptr(), LIST.len());
            let v = serde_json::from_slice(slice::from_raw_parts(out.data, out.len)).unwrap();
            airc_blocking_bytes_free(out);
            v
        };
        let rules = rules.as_array().unwrap();
        let exemption = rules.iter().position(|r| r["trigger"]["url-filter"] == ".*"
            && r["action"]["type"] == "ignore-previous-rules").expect("first-party document exemption");
        let after: Vec<_> = rules[exemption + 1..].iter().collect();
        assert!(after.iter().any(|r| r["action"]["type"] == "block"
            && r["trigger"]["url-filter"].as_str().unwrap().contains("page")
            && r["trigger"]["load-context"] == serde_json::json!(["top-frame"])));
        assert!(!after.iter().any(|r| r["action"]["type"] == "block"
            && r["trigger"]["url-filter"].as_str().unwrap().contains("plain")));
        assert!(after.iter().all(|r| r["action"]["type"] != "block" || (r["trigger"]["load-context"] == serde_json::json!(["top-frame"])
            && r["trigger"]["resource-type"] == serde_json::json!(["document"]))));
    }
}
