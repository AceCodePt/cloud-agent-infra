#!/usr/bin/env python3
"""
social-session.py — is a social account really logged in, in this browser profile?

Runs ON THE BOX (stdlib only, plus the openssl binary; nothing to pip install).

Two levels of proof, because they answer different questions:

  cookies (default)  Read the profile's cookie database and check that the set of
                     cookies is the one a SUCCESSFUL login produces. Costs no
                     network traffic at all and cannot be noticed by anyone.
                     Proves: a login completed and the server issued a session.

  --deep             Decrypt the session cookie and make ONE authenticated API
                     call. Proves the stronger thing: the session is still valid
                     right now AND works from this machine's egress IP, which is
                     the assumption the whole project rests on.

                     Deliberately not the default. This request comes from a
                     plain HTTP client, so its TLS/header fingerprint is not
                     Chrome's -- fine as an occasional diagnostic, wrong as a
                     routine health check. For routine use, read the cookies.

Exit status is the point: 0 = logged in, 1 = not logged in, 2 = could not tell.
"""
import argparse
import datetime
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

# Per-platform facts. Adding a platform means adding an entry, not writing code.
#
#   session   the cookie that only exists after a successful authentication
#   host      which cookie host it must be on (LinkedIn scopes li_at to
#             .www.linkedin.com, while its tracking cookies sit on .linkedin.com)
#   csrf      cookie whose value is echoed back as a CSRF header, if any
#   expect    other cookies a real logged-in session has, used as corroboration
#   probe     an endpoint that returns the member's own identity when authorised
PLATFORMS = {
    "linkedin": {
        "session": "li_at",
        "host": ".www.linkedin.com",
        "csrf": "JSESSIONID",
        "expect": ["bcookie", "bscookie", "lidc"],
        "probe": "https://www.linkedin.com/voyager/api/me",
        # A 403 here means the csrf-token header is missing or malformed. It does
        # NOT mean blocked, and mistaking one for the other leads to abandoning a
        # perfectly good session. Only a 302 to /uas/login means the session died.
        "headers": {
            "accept": "application/vnd.linkedin.normalized+json+2.1",
            "x-restli-protocol-version": "2.0.0",
            "x-li-lang": "en_US",
        },
    },
}

CHROME_EPOCH = datetime.datetime(1601, 1, 1)


def to_dt(webkit_us):
    """Chromium stores time as microseconds since 1601-01-01, not the Unix epoch."""
    if not webkit_us:
        return None
    return CHROME_EPOCH + datetime.timedelta(microseconds=webkit_us)


def read_cookies(profile, host_filter=None):
    """Snapshot the cookie DB and read it.

    The copy is not optional: Chromium holds the database open, and querying it
    in place either blocks or reads a half-written page. Copying costs
    milliseconds and removes the whole class of problem.
    """
    src = os.path.join(profile, "Default", "Cookies")
    if not os.path.exists(src):
        return None
    tmp = tempfile.mkdtemp(prefix="ck.")
    dst = os.path.join(tmp, "Cookies")
    try:
        shutil.copy2(src, dst)
        for extra in ("-wal", "-journal"):
            if os.path.exists(src + extra):
                shutil.copy2(src + extra, dst + extra)
        con = sqlite3.connect(dst)
        rows = con.execute(
            "select host_key, name, encrypted_value, expires_utc, is_httponly,"
            " is_secure, last_update_utc from cookies"
        ).fetchall()
        con.close()
        out = []
        for host, name, enc, exp, httponly, secure, upd in rows:
            if host_filter and host != host_filter:
                continue
            out.append(
                {
                    "host": host,
                    "name": name,
                    "enc": enc,
                    "expires": to_dt(exp),
                    "httponly": bool(httponly),
                    "secure": bool(secure),
                    "updated": to_dt(upd),
                }
            )
        return out
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def decrypt(enc, host_key):
    """Decrypt a Chromium cookie value on Linux.

    v10 means the value was encrypted with a hardcoded password, because no
    login keyring was available -- which is always the case on a headless box.
    v11 means a real keyring key, which we cannot get at from here.

    Chromium 130+ also prepends SHA256(host_key) to the plaintext, binding a
    cookie to its domain. Strip it only when it is actually there, so this keeps
    working on both sides of that change.
    """
    if not enc:
        return ""
    tag = bytes(enc[:3])
    if tag == b"v11":
        raise RuntimeError("cookie is keyring-encrypted (v11); cannot read it headlessly")
    if tag != b"v10":
        return bytes(enc).decode("utf-8", "replace")

    key = hashlib.pbkdf2_hmac("sha1", b"peanuts", b"saltysalt", 1, 16)
    proc = subprocess.run(
        ["openssl", "enc", "-d", "-aes-128-cbc", "-K", key.hex(), "-iv", "20" * 16, "-nopad"],
        input=bytes(enc[3:]),
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError("openssl could not decrypt the cookie: " + proc.stderr.decode()[:200])
    out = proc.stdout
    if out and 1 <= out[-1] <= 16:  # strip PKCS#7 padding
        out = out[: -out[-1]]
    prefix = hashlib.sha256(host_key.encode()).digest()
    if out.startswith(prefix):
        out = out[len(prefix):]
    return out.decode("utf-8", "replace")


def probe(spec, jar, ua):
    """One authenticated request. Returns (ok, detail)."""
    session = jar.get(spec["session"], "")
    csrf = jar.get(spec["csrf"], "") if spec.get("csrf") else ""
    cookie_hdr = "; ".join(f"{k}={v}" for k, v in jar.items() if v)

    headers = dict(spec["headers"])
    headers["cookie"] = cookie_hdr
    headers["user-agent"] = ua
    if csrf:
        # The header carries the value WITHOUT the surrounding quotes the cookie
        # has. Sending it quoted is the classic cause of a 403 that gets
        # misread as a ban.
        headers["csrf-token"] = csrf.strip('"')

    req = urllib.request.Request(spec["probe"], headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read(200000)
            status = r.status
            final = r.geturl()
    except urllib.error.HTTPError as e:
        status, body, final = e.code, e.read(4000), spec["probe"]
    except Exception as e:  # network-level
        return False, f"request failed: {e}"

    if "/uas/login" in final or "/checkpoint/" in final:
        return False, f"redirected to {final} -- the session is dead, log in again"
    if status == 401:
        return False, "401 unauthorised -- session no longer valid"
    if status == 403:
        return False, "403 -- almost always a missing/quoted csrf-token, NOT a ban"
    if status == 429:
        return False, "429 rate limited -- back off, the session itself is fine"
    if status != 200:
        return False, f"HTTP {status}"

    try:
        data = json.loads(body)
    except Exception:
        return True, f"HTTP 200 ({len(body)} bytes, not JSON)"

    # Pull out whatever identifies the member, without depending too hard on the
    # response shape, which LinkedIn changes freely.
    d = data.get("data", data)
    name = None
    for blob in (d, *(data.get("included") or [])):
        if isinstance(blob, dict):
            first = blob.get("firstName")
            last = blob.get("lastName")
            if first:
                name = f"{first} {last or ''}".strip()
                break
    urn = d.get("entityUrn") or d.get("*miniProfile") or ""
    return True, f"HTTP 200 as {name or '(name not in response)'} {urn}".strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("platform", choices=sorted(PLATFORMS))
    ap.add_argument("--profile", required=True)
    ap.add_argument("--deep", action="store_true", help="also make one authenticated request")
    ap.add_argument("--ua", default="", help="user agent to use for --deep")
    args = ap.parse_args()
    spec = PLATFORMS[args.platform]

    cookies = read_cookies(args.profile)
    if cookies is None:
        print(f"UNKNOWN  no cookie database in {args.profile} -- the browser has never run here")
        return 2

    by_name = {}
    for c in cookies:
        # Prefer the cookie on the exact host the platform scopes its session to.
        if c["name"] not in by_name or c["host"] == spec["host"]:
            by_name[c["name"]] = c

    sess = by_name.get(spec["session"])
    if not sess:
        print(f"NOT LOGGED IN  no {spec['session']} cookie ({len(cookies)} cookies present)")
        print("               visiting the login page alone sets tracking cookies;")
        print("               only a completed login sets the session cookie.")
        return 1

    now = datetime.datetime.utcnow()
    problems = []
    if sess["host"] != spec["host"]:
        problems.append(f"on host {sess['host']}, expected {spec['host']}")
    if not sess["httponly"]:
        problems.append("not httponly")
    if not sess["secure"]:
        problems.append("not secure")
    if sess["expires"] and sess["expires"] < now:
        problems.append(f"EXPIRED on {sess['expires']:%Y-%m-%d}")

    days = (sess["expires"] - now).days if sess["expires"] else None
    print(f"cookie   {spec['session']} on {sess['host']}")
    print(f"         issued/updated {sess['updated']:%Y-%m-%d %H:%M} UTC" if sess["updated"] else "")
    if days is not None:
        print(f"         expires {sess['expires']:%Y-%m-%d} ({days} days left)")
    missing = [n for n in spec["expect"] if n not in by_name]
    print(f"         corroborating cookies present: "
          f"{', '.join(n for n in spec['expect'] if n in by_name) or 'none'}"
          + (f" | MISSING {', '.join(missing)}" if missing else ""))

    if problems:
        print("SUSPECT  " + "; ".join(problems))
        return 1

    if not args.deep:
        print("LOGGED IN  (cookie evidence only; add --deep to prove the session is live)")
        return 0

    ua = args.ua or ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                     "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36")

    def attempt():
        """Read the cookies fresh, then probe. Fresh matters -- see below."""
        jar = {}
        for name in (spec["session"], spec.get("csrf")):
            if not name:
                continue
            cur = {c["name"]: c for c in sorted(read_cookies(args.profile) or [],
                                                key=lambda c: (c["host"] == spec["host"],
                                                               c["updated"] or CHROME_EPOCH))}
            if name in cur:
                jar[name] = decrypt(cur[name]["enc"], cur[name]["host"])
        return jar

    try:
        jar = attempt()
    except RuntimeError as e:
        print(f"UNKNOWN  {e}")
        return 2
    if not jar.get(spec["session"]):
        print("UNKNOWN  session cookie decrypted to an empty value")
        return 2

    ok, detail = probe(spec, jar, ua)

    # Retry once on a CSRF failure, because there is a benign cause that looks
    # identical to a real one. The CSRF cookie is a SESSION cookie: the browser
    # rotates it when it starts, and the on-disk copy lags the value the server
    # is expecting by a few seconds. Measured: 403 immediately after relaunching
    # the browser, then HTTP 200 twenty seconds later from the same code.
    # Reporting that as a failure would send you re-doing 2FA for no reason.
    if not ok and "403" in detail:
        print("         403 on the first try; the CSRF cookie rotates at browser")
        print("         start and the disk copy lags. Re-reading in 12s...")
        time.sleep(12)
        try:
            ok, detail = probe(spec, attempt(), ua)
        except RuntimeError as e:
            print(f"UNKNOWN  {e}")
            return 2

    print(("LOGGED IN  " if ok else "NOT USABLE  ") + detail)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
