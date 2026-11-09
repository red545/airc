# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
"""The posting queue for X: a pack's posts, scheduled three a day (a release's thread first, its replies a few seconds
apart under its first post), posted through X's API only once the owner has approved them.

    python3 tools/social/xpost.py plan <pack> [--start 2026-11-10] [--slots 09:00,15:00,21:00]   add a pack's posts
    python3 tools/social/xpost.py show                         the queue: when, what, approved, posted
    python3 tools/social/xpost.py review <id…> --by "<who>"     media looked at, text checked against the notes
    python3 tools/social/xpost.py approve <id…> | --through 2026-11-16 | --pack <slug>  --by "<the owner's words, where, when>"
    python3 tools/social/xpost.py unapprove <id…> | --all
    python3 tools/social/xpost.py start --by "<the owner's words, where, when>"    allow real runs (stop: pause)
    python3 tools/social/xpost.py drop <id…>                   take queued posts out (never posted ones only)
    python3 tools/social/xpost.py refresh <pack>               queued posts take the pack's edited text and media
    python3 tools/social/xpost.py preview                      check every queued post as run would, without posting
    python3 tools/social/xpost.py run [--dry]                  post what's approved and due (every few minutes)
    python3 tools/social/xpost.py pause [reason] | resume | stop
    python3 tools/social/xpost.py whoami                       the account the keys post as (one API read)
    python3 tools/social/xpost.py metrics                      each live post's numbers and the followers, saved
    python3 tools/social/xpost.py recap [--hours 24]           a plain-text recap: what went out, how it did, what's next
    python3 tools/social/xpost.py upload-test <file>           upload one image or video, post nothing

Nothing posts unless the owner has said to start posting (start), it's approved by the owner (approve, with who and
when logged), it's been reviewed since its text or media last changed (review), it's due, and the queue isn't paused.
Until start, only `run --dry`. A post with a link in its text is refused (X
charges much more for those, and the profile links the site). The first error pauses the queue with the reason. The keys
come from a JSON file outside the repo (AIRC_X_CREDENTIALS; api_key, api_key_secret, access_token, access_token_secret)
and are never printed. The queue, its log and each live post's link are in ARTIFACTS/_queue/.
"""
import base64
import datetime as dt
import fcntl
import hashlib
import hmac
import json
import mimetypes
import os
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import social
import studio

API = "https://api.x.com"
QUEUE_DIR = studio.ARTIFACTS / "_queue"
QUEUE = QUEUE_DIR / "queue.json"
LOG = QUEUE_DIR / "log.txt"
PAUSED = QUEUE_DIR / "PAUSED"
STARTED = QUEUE_DIR / "STARTED"
CREDENTIALS = Path(os.environ.get("AIRC_X_CREDENTIALS") or studio.ROOT.parent / "work" / "xpost" / "credentials.json")
# What X would turn into a link (and charge a link post's price for): a scheme, www., or a word.tld.
LINK = re.compile(r"https?://|www\.|\b[a-z0-9-]+\.(?:com|org|net|io|app|dev|co|ai|so|me|info|xyz|link|ly|gl)\b", re.I)
CHUNK = 4 * 1024 * 1024
REPLY_GAP_MIN = 0   # a thread goes out in one run, its replies a few seconds apart
# The owner's ceiling (2026-11-08): 10 posts a day, replies not counted. The plan uses three slots a day, about six hours
# apart, for a global audience; run also keeps two hours between top-level posts and posts one per run, so media that
# arrives late can't go out in a burst.
MAX_PER_DAY = 10
MIN_GAP = dt.timedelta(hours=2)


# MARK: The queue

def now():
    return dt.datetime.now(dt.timezone.utc)


def log(msg):
    QUEUE_DIR.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as f:
        f.write(f"{now():%Y-%m-%d %H:%M:%SZ} {msg}\n")


def load_queue():
    return json.loads(QUEUE.read_text()) if QUEUE.exists() else {"items": []}


def save_queue(q):
    QUEUE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = QUEUE.with_suffix(".tmp")
    tmp.write_text(json.dumps(q, indent=1, ensure_ascii=False))
    tmp.replace(QUEUE)


def media_for(pack_slug, refs):
    """A post's media refs → [{file, alt, kind}] from the built pack (16:9 where a ref names no size), or None while
    one isn't built yet. A ref can name another pack's media: "<pack slug>/<id>:<size>"."""
    out = []
    for ref in refs:
        slug, _, ref = ref.rpartition("/")
        d = studio.ARTIFACTS / (slug or pack_slug)
        m = json.loads((d / "pack.json").read_text()) if (d / "pack.json").exists() else {"images": [], "videos": []}
        rid, _, size = ref.partition(":")
        size = size or "16x9"
        rec = next((r for r in m["images"] if r["id"] == rid and r["size"] == size), None)
        rec = rec or next((v for v in m["videos"] if v["id"] == rid and v.get("kind") == size), None)
        if rec is None or not (d / rec["file"]).exists():
            return None
        out.append({"file": str(d / rec["file"]), "alt": rec.get("alt", ""),
                    "kind": "video" if rec["file"].endswith(".mp4") else "image"})
    return out


def digest(item):
    """What a review vouches for: the text, the media refs and the built files' sizes and times."""
    h = hashlib.sha256(item["text"].encode())
    h.update(json.dumps(item["media"]).encode())
    for x in media_for(item["pack"], item["media"]) or []:
        st = Path(x["file"]).stat()
        h.update(f"{Path(x['file']).name}:{st.st_size}:{int(st.st_mtime)}".encode())
    return h.hexdigest()[:16]


def reviewed(item):
    r = item.get("reviewed")
    return bool(r) and r.get("digest") == digest(item)


def problems(item):
    """Why an item can't go out as it is (empty when it can)."""
    out = []
    text = item["text"]
    if LINK.search(text):
        out.append(f"a link in the text ({LINK.search(text).group(0)})")
    n = social.x_length(text)
    if n > 280:
        out.append(f"{n} characters")
    media = media_for(item["pack"], item["media"])
    if media is None:
        out.append("media not built yet")
    else:
        kinds = {x["kind"] for x in media}
        if "video" in kinds and len(media) > 1:
            out.append("a video goes alone")
        if len(media) > 4:
            out.append("more than four images")
        for x in media:
            size = Path(x["file"]).stat().st_size
            if x["kind"] == "image" and size >= 5_000_000:
                out.append(f"{Path(x['file']).name} is {size / 1e6:.1f} MB")
    return out


# MARK: Commands

def cmd_plan(args):
    slug = args[0]
    opts = dict(zip(args[1::2], args[2::2]))
    pack = social.load(slug)
    q = load_queue()
    # A pack already in the queue adds only its new posts (appended to it since): the rest keep their place.
    have = {i["post"] for i in q["items"] if i["pack"] == pack["slug"]}
    start = dt.date.fromisoformat(opts.get("--start", now().date().isoformat()))
    slots = [tuple(int(x) for x in t.split(":")) for t in opts.get("--slots", "09:00,15:00,21:00").split(",")]
    tag = re.sub(r"[^a-z0-9]", "", pack["slug"].split("-", 3)[-1])[:10] or "pack"
    # Each top-level post takes the next free slot (none in the past, none another pack already has).
    taken = {i["due"] for i in q["items"] if not i["reply_to"]}

    def free_slots():
        day = start
        while True:
            for hh, mm in slots:
                at = dt.datetime(day.year, day.month, day.day, hh, mm, tzinfo=dt.timezone.utc)
                if at > now() + dt.timedelta(minutes=10) and at.isoformat() not in taken:
                    yield at
            day += dt.timedelta(days=1)

    next_slot = free_slots()
    prev, thread_at = None, None
    added = []
    for n, post in enumerate(pack.get("post", []), 1):
        if post.get("queue") is False or n in have:
            continue
        item = {"id": f"{tag}-{n:02d}", "pack": pack["slug"], "post": n, "label": post["label"],
                "text": post["text"].strip(), "media": post.get("media", []), "reply_to": None,
                "approved": False, "status": "queued", "posted": None, "error": ""}
        if post.get("reply") and prev is not None:
            # Under the post before it, in the same run: the release's thread, its pictures in the replies.
            item["reply_to"] = prev["id"]
            thread_at += dt.timedelta(minutes=REPLY_GAP_MIN)
            item["due"] = thread_at.isoformat()
        else:
            at = next(next_slot)
            item["due"] = at.isoformat()
            thread_at = at
        if post.get("note"):
            item["note"] = post["note"]
        q["items"].append(item)
        added.append(item)
        prev = item
    save_queue(q)
    log(f"planned {len(added)} posts of {pack['slug']} from {start}, slots {opts.get('--slots', '09:00,15:00,21:00')} UTC")
    for i in added:
        p = problems(i)
        print(f"  {i['id']}  {i['due'][:16].replace('T', ' ')}  {'↳ ' if i['reply_to'] else ''}{i['label']}"
              + (f"   [{'; '.join(p)}]" if p else ""))


def cmd_show(args):
    q = load_queue()
    if PAUSED.exists():
        print(f"PAUSED: {PAUSED.read_text().strip()}")
    for i in sorted(q["items"], key=lambda i: i["due"]):
        state = i["status"] if i["status"] != "queued" else ("approved" if i["approved"] else "not approved")
        if i["status"] == "queued":
            state += ", reviewed" if reviewed(i) else ""
        extra = f"  {i['posted']['url']}" if i.get("posted") else (f"  ({i['error']})" if i["error"] else "")
        print(f"{i['id']:10} {i['due'][:16].replace('T', ' ')}  {state:12} {'↳ ' if i['reply_to'] else ''}{i['label']}{extra}")


def take_by(args):
    """`--by "<who>"` out of args: who approved or reviewed, as the queue records it."""
    if "--by" not in args:
        return args, ""
    k = args.index("--by")
    return args[:k] + args[k + 2:], " ".join(args[k + 1:k + 2]).strip()


def cmd_approve(args, value=True):
    q = load_queue()
    args, by = take_by(args)
    if value and not by:
        raise SystemExit('approve needs --by "<the owner\'s words, where and when>": only the owner approves posts')
    if not args:
        raise SystemExit("approve which? ids, --through YYYY-MM-DD, --pack <slug> (unapprove also takes --all)")
    if args[0] == "--through":
        until = dt.datetime.fromisoformat(args[1] + "T23:59:59+00:00")
        pick = [i for i in q["items"] if dt.datetime.fromisoformat(i["due"]) <= until]
    elif args[0] == "--pack":
        pick = [i for i in q["items"] if i["pack"] == args[1]]
    elif args[0] == "--all" and not value:
        pick = q["items"]
    else:
        pick = [i for i in q["items"] if i["id"] in args]
    pick = [i for i in pick if i["status"] == "queued"]
    for i in pick:
        i["approved"] = value
        i["approved_by"] = {"by": by, "at": now().isoformat()} if value else None
    save_queue(q)
    log(f"{'approved' if value else 'unapproved'}{' by ' + by if by else ''}: {', '.join(i['id'] for i in pick) or 'nothing'}")
    print(f"{'approved' if value else 'unapproved'} {len(pick)}")


def cmd_review(args):
    """The studio's check before a post may go: its media built and looked at, its text against the published notes,
    nothing unreleased. Recorded with what it vouches for; a later change to the text or media voids it."""
    args, by = take_by(args)
    if not by or not args:
        raise SystemExit('review <id…> --by "<who looked>"')
    q = load_queue()
    done = []
    for i in q["items"]:
        if i["id"] in args and i["status"] == "queued":
            if media_for(i["pack"], i["media"]) is None:
                print(f"  {i['id']}: its media isn't built yet; not reviewed")
                continue
            i["reviewed"] = {"by": by, "at": now().isoformat(), "digest": digest(i)}
            done.append(i["id"])
    save_queue(q)
    log(f"reviewed by {by}: {', '.join(done) or 'nothing'}")
    print(f"reviewed {len(done)}")


def cmd_start(args):
    args, by = take_by(args)
    if not by:
        raise SystemExit('start needs --by "<the owner\'s words, where and when>": only the owner starts posting')
    STARTED.parent.mkdir(parents=True, exist_ok=True)
    STARTED.write_text(json.dumps({"by": by, "at": now().isoformat()}) + "\n")
    log(f"posting started by {by}")


def cmd_refresh(args):
    """A pack's queued posts take its current label, text and media (after an edit to the pack); the review of each
    changed post lapses with it (its digest no longer matches). Posts keep their place, as numbered when planned."""
    pack = social.load(args[0])
    posts = pack.get("post", [])
    q = load_queue()
    changed = []
    for i in q["items"]:
        if i["pack"] != pack["slug"] or i["status"] != "queued" or i["post"] > len(posts):
            continue
        post = posts[i["post"] - 1]
        new = {"label": post["label"], "text": post["text"].strip(), "media": post.get("media", [])}
        if any(i[k] != v for k, v in new.items()):
            i.update(new)
            changed.append(i["id"])
    save_queue(q)
    log(f"refreshed from {pack['slug']}: {', '.join(changed) or 'nothing changed'}")
    print(f"refreshed {len(changed)}: {' '.join(changed)}")


def cmd_drop(args):
    q = load_queue()
    keep = [i for i in q["items"] if not (i["id"] in args and i["status"] != "posted")]
    dropped = len(q["items"]) - len(keep)
    q["items"] = keep
    save_queue(q)
    log(f"dropped {dropped}: {', '.join(args)}")
    print(f"dropped {dropped}")


def cmd_preview(args):
    q = load_queue()
    bad = 0
    for i in sorted(q["items"], key=lambda i: i["due"]):
        if i["status"] != "queued":
            continue
        p = problems(i)
        bad += bool(p)
        print(f"{'✗' if p else '✓'} {i['id']:10} {i['due'][:16].replace('T', ' ')}  {i['label']}" + (f": {'; '.join(p)}" if p else ""))
    return 1 if bad else 0


# MARK: X's API (OAuth 1.0a, the app owner's own tokens)

def credentials():
    if not CREDENTIALS.exists():
        raise SystemExit(f"no X keys yet ({CREDENTIALS})")
    c = json.loads(CREDENTIALS.read_text())
    for k in ("api_key", "api_key_secret", "access_token", "access_token_secret"):
        if not c.get(k):
            raise SystemExit(f"the X keys file lacks {k}")
    return c


def _enc(s):
    return urllib.parse.quote(str(s), safe="~-._")


def oauth_header(method, url, creds, query=None):
    """OAuth 1.0a (HMAC-SHA1). A JSON or multipart body isn't part of the signature; query parameters are."""
    params = {"oauth_consumer_key": creds["api_key"], "oauth_nonce": secrets.token_hex(16),
              "oauth_signature_method": "HMAC-SHA1", "oauth_timestamp": str(int(time.time())),
              "oauth_token": creds["access_token"], "oauth_version": "1.0"}
    pairs = sorted((_enc(k), _enc(v)) for k, v in {**params, **(query or {})}.items())
    base = "&".join([method.upper(), _enc(url), _enc("&".join(f"{k}={v}" for k, v in pairs))])
    key = f"{_enc(creds['api_key_secret'])}&{_enc(creds['access_token_secret'])}"
    params["oauth_signature"] = base64.b64encode(hmac.new(key.encode(), base.encode(), hashlib.sha1).digest()).decode()
    return "OAuth " + ", ".join(f'{_enc(k)}="{_enc(v)}"' for k, v in sorted(params.items()))


class XError(Exception):
    pass


def request(method, path, creds, query=None, json_body=None, body=None, content_type=None):
    url = API + path
    headers = {"Authorization": oauth_header(method, url, creds, query), "User-Agent": "airc-social-studio"}
    data = None
    if json_body is not None:
        data = json.dumps(json_body).encode()
        headers["Content-Type"] = "application/json"
    elif body is not None:
        data, headers["Content-Type"] = body, content_type
    full = url + ("?" + urllib.parse.urlencode(query) if query else "")
    req = urllib.request.Request(full, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:600]
        raise XError(f"{method} {path}: HTTP {e.code} {detail}") from None
    except urllib.error.URLError as e:
        raise XError(f"{method} {path}: {e.reason}") from None


def multipart(fields, file_field, file_bytes):
    boundary = "airc" + secrets.token_hex(12)
    parts = []
    for k, v in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; filename="blob"\r\n'
                 f"Content-Type: application/octet-stream\r\n\r\n".encode() + file_bytes + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def upload(path, alt, creds):
    """Chunked upload (initialize, append, finalize, then status until a video is processed), then its alt text."""
    data = Path(path).read_bytes()
    mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
    category = "tweet_video" if mime.startswith("video/") else "tweet_image"
    init = request("POST", "/2/media/upload/initialize", creds,
                   json_body={"media_type": mime, "total_bytes": len(data), "media_category": category})
    mid = init["data"]["id"]
    for n, start in enumerate(range(0, len(data), CHUNK)):
        body, ctype = multipart({"segment_index": str(n)}, "media", data[start:start + CHUNK])
        request("POST", f"/2/media/upload/{mid}/append", creds, body=body, content_type=ctype)
    fin = request("POST", f"/2/media/upload/{mid}/finalize", creds).get("data", {})
    info = fin.get("processing_info")
    waited = 0
    while info and info.get("state") in ("pending", "in_progress"):
        wait = max(1, int(info.get("check_after_secs", 3)))
        time.sleep(wait)
        waited += wait
        if waited > 600:
            raise XError(f"{Path(path).name}: still processing after 10 minutes")
        info = request("GET", "/2/media/upload", creds, query={"command": "STATUS", "media_id": mid}).get("data", {}).get("processing_info")
    if info and info.get("state") == "failed":
        raise XError(f"{Path(path).name}: X couldn't process it: {json.dumps(info)[:300]}")
    if alt:
        text = alt if len(alt) <= 1000 else alt[:alt.rfind(". ", 0, 999) + 1] or alt[:1000]
        request("POST", "/2/media/metadata", creds, json_body={"id": mid, "metadata": {"alt_text": {"text": text}}})
    return mid


def cmd_whoami(args):
    me = request("GET", "/2/users/me", credentials())
    print(f"@{me['data']['username']} ({me['data']['name']})")


METRICS = QUEUE_DIR / "metrics.jsonl"


def cmd_metrics(args):
    """Each posted item's numbers (impressions and the rest where X gives them to the author) and the follower count,
    appended to metrics.jsonl. A post read costs about half a cent: run it once or twice a day."""
    creds = credentials()
    q = load_queue()
    posted = [i for i in q["items"] if i["status"] == "posted"]
    snap = {"at": now().isoformat(), "posts": {}, "followers": None}
    me = request("GET", "/2/users/me", creds, query={"user.fields": "public_metrics"})
    snap["followers"] = me["data"].get("public_metrics", {}).get("followers_count")
    for k in range(0, len(posted), 100):
        batch = posted[k:k + 100]
        ids = ",".join(i["posted"]["id"] for i in batch)
        try:
            res = request("GET", "/2/tweets", creds, query={"ids": ids, "tweet.fields": "public_metrics,non_public_metrics"})
        except XError:
            # Non-public numbers are the author's for 30 days; past that, the public ones.
            res = request("GET", "/2/tweets", creds, query={"ids": ids, "tweet.fields": "public_metrics"})
        for t in res.get("data", []):
            m = dict(t.get("public_metrics", {}))
            m.update({f"np_{k2}": v for k2, v in t.get("non_public_metrics", {}).items()})
            snap["posts"][t["id"]] = m
    QUEUE_DIR.mkdir(parents=True, exist_ok=True)
    with METRICS.open("a") as f:
        f.write(json.dumps(snap) + "\n")
    print(f"metrics: {len(snap['posts'])} posts, {snap['followers']} followers")


def cmd_recap(args):
    hours = int(dict(zip(args[::2], args[1::2])).get("--hours", "24"))
    since = now() - dt.timedelta(hours=hours)
    q = load_queue()
    snaps = [json.loads(l) for l in METRICS.read_text().splitlines()] if METRICS.exists() else []
    last = snaps[-1] if snaps else {"posts": {}, "followers": None}
    before = next((s for s in reversed(snaps) if dt.datetime.fromisoformat(s["at"]) <= since), snaps[0] if snaps else None)
    out = [f"Airc on X, recap for the {hours} hours to {now():%Y-%m-%d %H:%M} UTC"]
    if PAUSED.exists():
        out.append(f"!! The queue is PAUSED: {PAUSED.read_text().strip()}")
    if last.get("followers") is not None:
        delta = (last["followers"] - before["followers"]) if before and before.get("followers") is not None else None
        out.append(f"Followers: {last['followers']}" + (f" ({delta:+d})" if delta is not None else ""))
    def views(m):
        return m.get("np_impression_count", m.get("impression_count", 0))
    posted = [i for i in q["items"] if i["status"] == "posted"]
    recent = [i for i in posted if dt.datetime.fromisoformat(i["posted"]["at"]) >= since]
    out.append(f"\nPosted ({len(recent)}):")
    for i in sorted(recent, key=lambda i: i["posted"]["at"]):
        m = last["posts"].get(i["posted"]["id"], {})
        out.append(f"- {i['posted']['at'][11:16]} {'↳ ' if i['reply_to'] else ''}{i['label']}: {views(m)} views, "
                   f"{m.get('like_count', 0)} likes, {m.get('retweet_count', 0)} reposts, {m.get('reply_count', 0)} replies, "
                   f"{m.get('bookmark_count', 0)} bookmarks  {i['posted']['url']}")
    ranked = sorted(posted, key=lambda i: views(last["posts"].get(i["posted"]["id"], {})), reverse=True)[:3]
    if ranked and last["posts"]:
        out.append("\nBest so far (views):")
        for i in ranked:
            m = last["posts"].get(i["posted"]["id"], {})
            out.append(f"- {i['label']}: {views(m)} views, {m.get('like_count', 0)} likes")
    nxt = [i for i in sorted(q["items"], key=lambda i: i["due"]) if i["status"] == "queued"
           and dt.datetime.fromisoformat(i["due"]) <= now() + dt.timedelta(hours=24)]
    out.append(f"\nNext 24 hours ({len(nxt)}):")
    for i in nxt:
        why = "" if reviewed(i) and i["approved"] else " [waiting: " + ", ".join(
            x for x, c in (("not approved", not i["approved"]), ("not reviewed", not reviewed(i)),
                           ("media not built", media_for(i["pack"], i["media"]) is None)) if c) + "]"
        out.append(f"- {i['due'][11:16]} {'↳ ' if i['reply_to'] else ''}{i['label']}{why}")
    stuck = [i for i in q["items"] if i["status"] == "queued" and dt.datetime.fromisoformat(i["due"]) < now() - dt.timedelta(hours=6)]
    if stuck:
        out.append(f"\nOverdue by 6 h or more ({len(stuck)}): " + ", ".join(f"{i['id']} ({i['error'] or 'waiting'})" for i in stuck))
    print("\n".join(out))


def cmd_upload_test(args):
    """Uploads one file with its alt text and posts nothing (X drops unused media after a day): the keys and the
    upload path work before the first post is due."""
    print(f"media id {upload(args[0], 'Upload test from the Airc social studio.', credentials())}: uploaded, not posted")


def cmd_run(args):
    dry = "--dry" in args
    QUEUE_DIR.mkdir(parents=True, exist_ok=True)
    with open(QUEUE_DIR / ".run.lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0   # another run is posting
        if PAUSED.exists():
            return 0
        if not dry and not STARTED.exists():
            print("posting hasn't been started by the owner (xpost.py start); only run --dry", file=sys.stderr)
            return 1
        q = load_queue()
        by_id = {i["id"]: i for i in q["items"]}
        due = [i for i in sorted(q["items"], key=lambda i: i["due"])
               if i["status"] == "queued" and i["approved"] and dt.datetime.fromisoformat(i["due"]) <= now()]
        creds = None
        top_posted = sorted(dt.datetime.fromisoformat(i["posted"]["at"]) for i in q["items"]
                            if i["status"] == "posted" and not i["reply_to"])
        top_this_run = 0
        for i in due:
            parent = by_id.get(i["reply_to"]) if i["reply_to"] else None
            if parent is None:
                # A top-level post: one per run, two hours after the last, ten a day at most.
                recent = [t for t in top_posted if t > now() - dt.timedelta(hours=24)]
                if top_this_run or len(recent) >= MAX_PER_DAY or (top_posted and now() - top_posted[-1] < MIN_GAP):
                    continue
            if parent is not None and parent["status"] != "posted":
                continue   # its thread's post before it isn't up yet
            if not i.get("approved_by", {}) or not i["approved_by"].get("by"):
                continue   # approved without the owner's name: never posted
            p = problems(i)
            if not p and not reviewed(i):
                if i["error"] != "not reviewed":
                    i["error"] = "not reviewed"
                    log(f"{i['id']} waits: not reviewed since its text or media changed")
                continue
            if p == ["media not built yet"]:
                if i["error"] != p[0]:
                    i["error"] = p[0]
                    log(f"{i['id']} waits: its media isn't built yet")
                continue
            if p:
                return pause(q, f"{i['id']} can't go out: {'; '.join(p)}")
            media = media_for(i["pack"], i["media"])
            if dry:
                print(f"would post {i['id']} ({i['label']}): {len(media)} media, "
                      f"{'reply to ' + i['reply_to'] if i['reply_to'] else 'new post'}")
                continue
            creds = creds or credentials()
            try:
                ids = [upload(x["file"], x["alt"], creds) for x in media]
                body = {"text": i["text"]}
                if ids:
                    body["media"] = {"media_ids": ids}
                if parent is not None:
                    body["reply"] = {"in_reply_to_tweet_id": parent["posted"]["id"]}
                res = request("POST", "/2/tweets", creds, json_body=body)
            except XError as e:
                i["error"] = str(e)
                return pause(q, f"{i['id']}: {e}")
            pid = res["data"]["id"]
            i.update(status="posted", error="", posted={"id": pid, "url": f"https://x.com/i/status/{pid}", "at": now().isoformat()})
            if parent is None:
                top_this_run += 1
                top_posted.append(now())
            else:
                time.sleep(15)
            save_queue(q)
            log(f"posted {i['id']} ({i['label']}): {i['posted']['url']}")
        save_queue(q)
    return 0


def pause(q, reason):
    save_queue(q)
    PAUSED.write_text(reason + "\n")
    log(f"PAUSED: {reason}")
    print(f"paused: {reason}", file=sys.stderr)
    return 1


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd, args = argv[1], argv[2:]
    if cmd == "plan":
        cmd_plan(args)
    elif cmd == "show":
        cmd_show(args)
    elif cmd == "approve":
        cmd_approve(args, True)
    elif cmd == "unapprove":
        cmd_approve(args, False)
    elif cmd == "drop":
        cmd_drop(args)
    elif cmd == "refresh":
        cmd_refresh(args)
    elif cmd == "review":
        cmd_review(args)
    elif cmd == "start":
        cmd_start(args)
    elif cmd == "preview":
        return cmd_preview(args)
    elif cmd == "run":
        return cmd_run(args)
    elif cmd == "pause":
        PAUSED.parent.mkdir(parents=True, exist_ok=True)
        PAUSED.write_text((" ".join(args) or "paused by hand") + "\n")
        log(f"PAUSED: {' '.join(args) or 'by hand'}")
    elif cmd == "resume":
        PAUSED.unlink(missing_ok=True)
        log("resumed")
    elif cmd == "stop":
        STARTED.unlink(missing_ok=True)
        log("posting stopped (start again needs the owner)")
    elif cmd == "whoami":
        cmd_whoami(args)
    elif cmd == "upload-test":
        cmd_upload_test(args)
    elif cmd == "metrics":
        cmd_metrics(args)
    elif cmd == "recap":
        cmd_recap(args)
    else:
        print(f"unknown command {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
