#!/usr/bin/env python3
"""
gsc.py: report Google Search Console status for a site from the command line.

Read-only. Talks to the Search Console API with a service account key, using
`google-auth` to sign the credential and stdlib urllib for every HTTP call, the
token request included. Python 3.9+ and `google-auth` are the only
requirements, so the script drops into any static-site repository.

Usage:
  gsc.py index [--days N]          inspect every <loc> in the sitemap: verdict, coverage, last crawl, canonical
  gsc.py sitemap                   sitemaps.get: last submitted, last downloaded, pending, errors, indexed counts
  gsc.py perf [--days 28]          searchanalytics.query by page and by query: clicks, impressions, CTR, position

Common options:
  --property  sc-domain:example.com | https://example.com/   (else $GSC_PROPERTY, else derived from the sitemap)
  --sitemap   path/to/sitemap.xml | https://example.com/sitemap.xml   (default: ./public/sitemap.xml)
  --project   Google Cloud project that owns the key         (else $GSC_PROJECT, else derived from the property)
  --json      dump the raw API responses instead of the tables
  --key       service account key file                       (else $GSC_SA_KEY, else ~/.config/<project>/gsc-sa.json)

Exit status is non-zero on a real problem: no credential, an API error, a page
that Google could not fetch, a page blocked by robots.txt or noindex. A page
that is simply not indexed yet is normal and does not fail the run.

Setup, quotas and what stays manual: SKILL.md, one directory above this file.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET  # parses only the site's own sitemap.xml
from pathlib import Path

SCOPE = "https://www.googleapis.com/auth/webmasters.readonly"
WEBMASTERS = "https://www.googleapis.com/webmasters/v3"
SEARCHCONSOLE = "https://searchconsole.googleapis.com/v1"
DEFAULT_SITEMAP = "public/sitemap.xml"
SITEMAP_NS = "{http://www.sitemaps.org/schemas/sitemap/0.9}"

# Index states that are not a problem. Anything else is a real failure, as
# opposed to "discovered, not indexed yet", which is normal for a new page.
OK_FETCH_STATES = {"", "SUCCESSFUL", "PAGE_FETCH_STATE_UNSPECIFIED"}
OK_ROBOTS_STATES = {"", "ALLOWED", "ROBOTS_TXT_STATE_UNSPECIFIED"}
OK_INDEXING_STATES = {"", "INDEXING_ALLOWED", "INDEXING_STATE_UNSPECIFIED"}
INDEXED_VERDICTS = {"PASS", "PARTIAL"}

RECRAWL_DOC = "https://developers.google.com/search/docs/crawling-indexing/ask-google-to-recrawl"


class Failure(Exception):
    """A condition the user has to fix. Printed as FAIL, exits non-zero."""


def fail(msg):
    print(f"  FAIL  {msg}")


def warn(msg):
    print(f"  WARN  {msg}")


def ok(msg):
    print(f"  ok    {msg}")


# --- property, sitemap, project, key: all resolved from arguments or environment ---


def normalize_property(raw):
    """Accept a Domain property, a URL-prefix property, or a bare host."""
    value = (raw or "").strip()
    if not value:
        return None
    if value.startswith("sc-domain:"):
        return "sc-domain:" + value[len("sc-domain:"):].strip().strip("/")
    if value.startswith(("http://", "https://")):
        return value if value.endswith("/") else value + "/"
    return "sc-domain:" + value.strip("/")


def property_from_locs(locs):
    """A sitemap's own host implies the Domain property for that host."""
    for loc in locs:
        host = urllib.parse.urlparse(loc).netloc
        if host:
            return "sc-domain:" + host
    return None


def resolve_property(explicit, env_value, locs):
    """Return (property, how it was found). Raises Failure if nothing resolves."""
    prop = normalize_property(explicit)
    if prop:
        return prop, "--property"
    prop = normalize_property(env_value)
    if prop:
        return prop, "$GSC_PROPERTY"
    prop = property_from_locs(locs)
    if prop:
        return prop, "assumed from the sitemap host"
    raise Failure("no Search Console property: pass --property sc-domain:example.com or set $GSC_PROPERTY")


def encode_property(prop):
    """The siteUrl path segment, colons and slashes percent-encoded."""
    return urllib.parse.quote(prop, safe="")


def resolve_sitemap_source(explicit, cwd):
    """Return ('url'|'file', value) for the sitemap to read."""
    if explicit:
        if explicit.startswith(("http://", "https://")):
            return "url", explicit
        return "file", str(Path(explicit).expanduser())
    default = Path(cwd) / DEFAULT_SITEMAP
    if default.is_file():
        return "file", str(default)
    raise Failure(f"no sitemap: {DEFAULT_SITEMAP} not found here, pass --sitemap <path or https URL>")


def sitemap_locs(xml_text):
    """Every <loc> in a sitemap, in document order."""
    root = ET.fromstring(xml_text)
    locs = []
    for el in root.iter(f"{SITEMAP_NS}loc"):
        text = (el.text or "").strip()
        if text:
            locs.append(text)
    return locs


def feed_url(kind, value, prop):
    """The sitemap URL Google was given, which is what sitemaps.get keys on."""
    if kind == "url":
        return value
    if prop.startswith("sc-domain:"):
        return f"https://{prop[len('sc-domain:'):]}/sitemap.xml"
    return prop.rstrip("/") + "/sitemap.xml"


def property_host(prop):
    """example.com for sc-domain:example.com and for https://example.com/."""
    if prop.startswith("sc-domain:"):
        return prop[len("sc-domain:"):]
    return urllib.parse.urlparse(prop).netloc


def project_slug(prop):
    """A stable directory name for a property: example.com -> example-com."""
    host = prop[len("sc-domain:"):] if prop.startswith("sc-domain:") else urllib.parse.urlparse(prop).netloc
    return host.replace(".", "-") or "gsc"


def key_path(explicit, env_key, project):
    if explicit:
        return Path(explicit).expanduser()
    if env_key:
        return Path(env_key).expanduser()
    return Path.home() / ".config" / project / "gsc-sa.json"


# --- auth and HTTP ---


def setup_script():
    """The sibling setup.sh, as an absolute path, so the hint is copy-pasteable."""
    return Path(__file__).resolve().parent / "setup.sh"


def missing_key_message(path):
    return (
        f"no service account key at {path}\n"
        "        Create one and grant it access (about two minutes):\n"
        f"          {setup_script()} --project <gcp-project>\n"
        "        then Search Console > the property > Settings > Users and permissions >\n"
        "        Add user > the service account email > permission Full > Add.\n"
        "        Point $GSC_SA_KEY at the key file if it lives somewhere else."
    )


def classify_api_error(status, body):
    """Turn an API error into the specific thing to fix."""
    text = body if isinstance(body, str) else str(body)
    if status == 403 and "ACCESS_TOKEN_SCOPE_INSUFFICIENT" in text:
        return (f"403: the credential is missing the {SCOPE} scope. "
                "The script requests it, so a stale cached token or a hand-made key is the usual cause.")
    if status == 403 and "sufficient permission for site" in text:
        return ("403: Search Console does not know this service account. Add its email in "
                "Search Console > Settings > Users and permissions > Add user, with permission Full. "
                "Restricted is not enough.")
    if status == 403:
        return f"403: the Search Console API rejected the call. {text[:300]}"
    if status == 401:
        return "401: the key was rejected. It may have been deleted or the service account disabled. Re-run setup.sh --rotate."
    if status == 404:
        return ("404: no such property. A Domain property is spelled sc-domain:example.com; "
                "https://example.com/ is a different property and may not exist.")
    if status == 429:
        return "429: quota exceeded. URL Inspection allows 2,000 calls per property per day. Try again tomorrow."
    return f"HTTP {status}: {text[:300]}"


class UrllibResponse:
    """The three attributes google-auth reads off a transport response."""

    def __init__(self, status, headers, data):
        self.status = status
        self.headers = headers
        self.data = data


def urllib_transport(url, method="GET", body=None, headers=None, timeout=60, **_kwargs):
    """A google.auth transport built on urllib.

    google-auth ships `google.auth.transport.requests`, but importing it needs
    the third-party `requests` package, which `pip install google-auth` does not
    pull in. This does the same job with the standard library, so `google-auth`
    really is the only dependency. An error status is a normal response here:
    google-auth reads the body to report what the token endpoint refused.
    """
    req = urllib.request.Request(url, data=body, method=method)
    for name, value in (headers or {}).items():
        req.add_header(name, value)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return UrllibResponse(resp.status, dict(resp.headers), resp.read())
    except urllib.error.HTTPError as exc:
        with exc:
            return UrllibResponse(exc.code, dict(exc.headers or {}), exc.read())


def access_token(path):
    """Mint a read-only bearer token from the service account key."""
    if not path.is_file():
        raise Failure(missing_key_message(path))
    try:
        from google.oauth2 import service_account
    except ImportError:
        raise Failure("google-auth is not installed: python3 -m pip install --user google-auth") from None
    try:
        creds = service_account.Credentials.from_service_account_file(str(path), scopes=[SCOPE])
        creds.refresh(urllib_transport)
    except Exception as exc:  # a bad key, a clock skew, no network
        raise Failure(f"could not authenticate with {path}: {exc}")
    return creds.token  # never printed


def call(token, url, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    req.add_header("Authorization", f"Bearer {token}")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        raise Failure(classify_api_error(exc.code, exc.read().decode("utf-8", "replace")))
    except urllib.error.URLError as exc:
        raise Failure(f"could not reach the Search Console API: {exc.reason}")


def read_sitemap(kind, value):
    if kind == "file":
        path = Path(value)
        if not path.is_file():
            raise Failure(f"no sitemap at {path}")
        text = path.read_text(encoding="utf-8")
    else:
        try:
            with urllib.request.urlopen(value, timeout=30) as resp:
                text = resp.read().decode("utf-8", "replace")
        except (urllib.error.URLError, urllib.error.HTTPError) as exc:
            raise Failure(f"could not fetch {value}: {exc}")
    try:
        locs = sitemap_locs(text)
    except ET.ParseError as exc:
        raise Failure(f"{value} is not valid XML: {exc}")
    if not locs:
        raise Failure(f"{value} lists no <loc> URLs")
    return locs


# --- formatting ---


def render_table(headers, rows):
    """A plain left-aligned table as a list of lines. Pure, so it is testable."""
    cols = [[str(h)] + [str(r[i]) for r in rows] for i, h in enumerate(headers)]
    widths = [max(len(c) for c in col) for col in cols]
    lines = ["  " + "  ".join(str(h).ljust(w) for h, w in zip(headers, widths)).rstrip()]
    lines.append("  " + "  ".join("-" * w for w in widths))
    for row in rows:
        lines.append("  " + "  ".join(str(c).ljust(w) for c, w in zip(row, widths)).rstrip())
    return lines


def short_path(url, host=None):
    """The part of a result URL worth reading in a table.

    Google reports a fragment as its own row (`/#work` is not `/`), and a Domain
    property covers every host under the domain, so both have to survive or
    unrelated rows look like duplicates of the home page.
    """
    parsed = urllib.parse.urlparse(url)
    tail = (parsed.path or "/") + (f"?{parsed.query}" if parsed.query else "")
    tail += f"#{parsed.fragment}" if parsed.fragment else ""
    if parsed.netloc and host and parsed.netloc != host:
        return parsed.netloc + tail
    return tail


def as_date(value):
    """2026-09-14T10:02:31Z -> 2026-09-14. Missing stays visible as a dash."""
    if not value:
        return "-"
    return str(value).split("T", 1)[0]


def canonical_mismatch(status):
    """Google picked a different canonical than the page declares."""
    google = (status.get("googleCanonical") or "").rstrip("/")
    user = (status.get("userCanonical") or "").rstrip("/")
    return bool(google and user and google != user)


def is_indexed(status):
    return status.get("verdict") in INDEXED_VERDICTS


def index_problem(status):
    """A real failure, or None. 'Not indexed yet' is not a failure."""
    fetch = status.get("pageFetchState", "")
    if fetch not in OK_FETCH_STATES:
        return f"page fetch {fetch}"
    if status.get("robotsTxtState", "") not in OK_ROBOTS_STATES:
        return f"robots.txt {status.get('robotsTxtState')}"
    if status.get("indexingState", "") not in OK_INDEXING_STATES:
        return f"indexing {status.get('indexingState')}"
    return None


def index_row(url, result):
    """One table row: path, verdict, coverage, last crawl, canonical marker."""
    status = (result or {}).get("inspectionResult", {}).get("indexStatusResult", {})
    return [
        short_path(url),
        status.get("verdict", "-"),
        status.get("coverageState", "-"),
        as_date(status.get("lastCrawlTime")),
        "canonical mismatch" if canonical_mismatch(status) else "",
    ]


def pct(value):
    return f"{float(value or 0) * 100:.1f}%"


# --- subcommands ---


def cmd_index(opts, token):
    locs = opts["locs"]
    url = f"{SEARCHCONSOLE}/urlInspection/index:inspect"
    results, raw = [], {}
    for loc in locs:
        raw[loc] = call(token, url, {"inspectionUrl": loc, "siteUrl": opts["property"]})
        results.append((loc, raw[loc]))
    if opts["json"]:
        print(json.dumps(raw, indent=2))
    problems = []
    pending = []
    for loc, result in results:
        status = result.get("inspectionResult", {}).get("indexStatusResult", {})
        reason = index_problem(status)
        if reason:
            problems.append((loc, reason))
        elif not is_indexed(status):
            pending.append((loc, result.get("inspectionResult", {}).get("inspectionResultLink", "")))
    if not opts["json"]:
        print(f"Index status for {opts['property']} ({len(locs)} URLs, {len(locs)} of 2,000 daily inspections)")
        print()
        for line in render_table(["PATH", "VERDICT", "COVERAGE", "LAST CRAWL", "NOTE"],
                                 [index_row(loc, result) for loc, result in results]):
            print(line)
        print()
        if pending:
            print("Not on Google yet. These are the only URLs where clicking Request indexing in the UI")
            print("is worth anything, and clicking it twice buys nothing:")
            print(f"  {RECRAWL_DOC}")
            print()
            for loc, link in pending:
                print(f"  {short_path(loc)}")
                print(f"    {link or 'no inspection link returned'}")
            print()
        else:
            ok("every sitemap URL is on Google")
    for loc, reason in problems:
        fail(f"{short_path(loc)}: {reason}")
    return 1 if problems else 0


def cmd_sitemap(opts, token):
    feed = opts["feed_url"]
    url = f"{WEBMASTERS}/sites/{encode_property(opts['property'])}/sitemaps/{urllib.parse.quote(feed, safe='')}"
    result = call(token, url)
    if opts["json"]:
        print(json.dumps(result, indent=2))
        return 0
    print(f"Sitemap {feed}")
    print()
    errors = int(result.get("errors", 0) or 0)
    warnings = int(result.get("warnings", 0) or 0)
    rows = [
        ["last submitted", as_date(result.get("lastSubmitted"))],
        ["last downloaded", as_date(result.get("lastDownloaded"))],
        ["pending", "yes" if result.get("isPending") else "no"],
        ["errors", errors],
        ["warnings", warnings],
    ]
    for content in result.get("contents", []):
        rows.append([f"{str(content.get('type', 'web')).lower()} submitted", content.get("submitted", "-")])
        rows.append([f"{str(content.get('type', 'web')).lower()} indexed", content.get("indexed", "-")])
    for line in render_table(["FIELD", "VALUE"], rows):
        print(line)
    print()
    if not result.get("lastDownloaded"):
        warn("Google has never downloaded this sitemap. A sitemap submitted in the last day or two "
             "often reads this way; if it stays this way for several days, delete it in "
             "Search Console > Sitemaps and submit it once more.")
    else:
        ok("Google has downloaded the sitemap")
    if errors:
        fail(f"{errors} sitemap error(s): open Search Console > Sitemaps for the detail")
        return 1
    return 0


def cmd_perf(opts, token):
    url = f"{WEBMASTERS}/sites/{encode_property(opts['property'])}/searchAnalytics/query"
    start, end = opts["start_date"], opts["end_date"]
    raw = {}
    for dimension in ("page", "query"):
        raw[dimension] = call(token, url, {
            "startDate": start,
            "endDate": end,
            "dimensions": [dimension],
            "rowLimit": 25000,
            "dataState": "all",
        })
    if opts["json"]:
        print(json.dumps(raw, indent=2))
        return 0
    print(f"Search performance for {opts['property']}, {start} to {end} ({opts['days']} days)")
    incomplete = (raw["page"].get("metadata") or {}).get("first_incomplete_date")
    if incomplete:
        print(f"Data from {incomplete} onward is provisional and will still move.")
    print()
    for dimension, label in (("page", "BY PAGE"), ("query", "BY QUERY")):
        rows = raw[dimension].get("rows", [])
        print(f"{label}  ({len(rows)} rows)")
        if rows:
            table = [[
                short_path(r["keys"][0], property_host(opts["property"])) if dimension == "page" else r["keys"][0],
                r.get("clicks", 0),
                r.get("impressions", 0),
                pct(r.get("ctr")),
                f"{float(r.get('position', 0)):.1f}",
            ] for r in rows]
            for line in render_table(["KEY", "CLICKS", "IMPR", "CTR", "POS"], table):
                print(line)
        elif dimension == "query":
            print("  No queries above Google's privacy threshold yet. That is the normal state for a")
            print("  small site: rare queries are withheld, so the query table stays empty until volume")
            print("  grows. Page rows are not anonymized, so use those instead.")
        else:
            print("  No impressions in this window yet.")
        print()
    return 0


# --- entry point ---


def parse_args(argv):
    opts = {"json": False, "days": 28, "property": None, "sitemap": None, "project": None, "key": None}
    if not argv or argv[0].startswith("-"):
        raise Failure("usage: gsc.py index|sitemap|perf [--property P] [--sitemap S] [--days N] [--json]")
    command = argv[0]
    if command not in ("index", "sitemap", "perf"):
        raise Failure(f"unknown command {command!r}: expected index, sitemap or perf")
    rest = argv[1:]
    while rest:
        flag = rest.pop(0)
        if flag == "--json":
            opts["json"] = True
        elif flag in ("--days", "--property", "--sitemap", "--project", "--key"):
            if not rest:
                raise Failure(f"{flag} needs a value")
            opts[flag[2:]] = rest.pop(0)
        else:
            raise Failure(f"unknown option {flag!r}")
    try:
        opts["days"] = max(1, int(opts["days"]))
    except (TypeError, ValueError):
        raise Failure("--days takes a whole number of days")
    return command, opts


def run(argv, env, cwd):
    import datetime

    command, opts = parse_args(argv)
    kind, source = resolve_sitemap_source(opts["sitemap"] or env.get("GSC_SITEMAP"), cwd)
    try:
        locs = read_sitemap(kind, source)
    except Failure:
        if command == "index":
            raise  # index has nothing to inspect without it
        locs = []  # sitemap and perf only read it to guess the property
    prop, how = resolve_property(opts["property"], env.get("GSC_PROPERTY"), locs)
    project = opts["project"] or env.get("GSC_PROJECT") or project_slug(prop)
    opts.update({
        "property": prop,
        "locs": locs,
        "feed_url": feed_url(kind, source, prop),
        "project": project,
    })
    today = datetime.date.today()
    opts["end_date"] = today.isoformat()
    opts["start_date"] = (today - datetime.timedelta(days=opts["days"])).isoformat()
    if not opts["json"]:
        print(f"Property {prop} ({how}); sitemap {source}")
        print()
    token = access_token(key_path(opts["key"], env.get("GSC_SA_KEY"), project))
    return {"index": cmd_index, "sitemap": cmd_sitemap, "perf": cmd_perf}[command](opts, token)


def main(argv):
    try:
        return run(argv, os.environ, Path.cwd())
    except Failure as exc:
        fail(str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
