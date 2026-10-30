#!/usr/bin/env python3
"""
mail.py: read, send and manage the mail of a domain whose every address is an alias.

The system it talks to: Amazon SES receives every address at the domain, stores each message in
an S3 bucket (raw/<SES message id>) and a Lambda forwards it to the owner, indexing it in a
DynamoDB table. This script reads that table and bucket, sends as any alias through SES, blocks
or names aliases, and asks the Lambda to forward a stored message again.

Usage:
  mail.py aliases [--state forward|archive|block]
  mail.py alias <local> [--block | --forward | --archive] [--name "..."] [--note "..."]
  mail.py ls [--alias <local>] [--since 7d] [--spam] [--unforwarded] [-n 20]
  mail.py read <id> [--raw | --save-attachments DIR]
  mail.py send --from <local> --to <address> --subject "..." (--body "..." | --body-file F) [--attach F ...]
  mail.py reply <id> (--body "..." | --body-file F) [--attach F ...]
  mail.py forward <id>
  mail.py status

Every command takes --json, and --table, --bucket, --domain, --function, --config-set and
--region (else $MAIL_TABLE, $MAIL_BUCKET, $MAIL_DOMAIN, $MAIL_FUNCTION, $MAIL_CONFIG_SET, and
$MAIL_REGION or the AWS environment). Credentials are the AWS environment's.

Needs Python 3.11+ and boto3. Exit status: 0 done, 1 refused or failed, 2 usage or setup.
Setup, the table's shape and the sending rule: SKILL.md, one directory above this file.
"""

import argparse
import email
import email.policy
import email.utils
import json
import mimetypes
import re
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from email.message import EmailMessage
from html.parser import HTMLParser
from pathlib import Path
from typing import Optional

if sys.version_info < (3, 11):
    sys.exit("mail.py needs Python 3.11 or newer")

PROTECTED = frozenset({"postmaster", "abuse", "dmarc"})
STATES = ("forward", "archive", "block")
INSTALL_BOTO3 = "python3 -m pip install --user boto3"


class Refused(Exception):
    """A request the script will not carry out; printed, exit status 1."""


@dataclass(frozen=True)
class Settings:
    table: str
    bucket: str
    domain: str
    function: Optional[str]
    config_set: str
    region: Optional[str]


def resolve(args, env) -> Settings:
    """Flags first, then the environment. A missing table, bucket or domain exits 2."""
    def pick(name, var):
        return getattr(args, name, None) or env.get(var)

    missing = [f"--{flag} (or ${var})" for name, flag, var in (
        ("table", "table", "MAIL_TABLE"), ("bucket", "bucket", "MAIL_BUCKET"), ("domain", "domain", "MAIL_DOMAIN"))
        if not pick(name, var)]
    if missing:
        print("mail: missing " + ", ".join(missing), file=sys.stderr)
        raise SystemExit(2)
    return Settings(
        table=pick("table", "MAIL_TABLE"),
        bucket=pick("bucket", "MAIL_BUCKET"),
        domain=pick("domain", "MAIL_DOMAIN").lower(),
        function=pick("function", "MAIL_FUNCTION"),
        config_set=pick("config_set", "MAIL_CONFIG_SET") or "mail",
        region=getattr(args, "region", None) or env.get("MAIL_REGION") or env.get("AWS_REGION") or env.get("AWS_DEFAULT_REGION"),
    )


# -- text that came from strangers, made safe for a terminal ------------------------------------

_OSC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?")
_CSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
# C0 and C1 controls (0x9b is an 8-bit CSI) and the bidi overrides and isolates that can make
# text read in a different order than it is.
_CONTROL = re.compile("[\x00-\x08\x0b-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069\u200e\u200f\u061c]")


def safe(text) -> str:
    """Drop terminal escape sequences and control characters (tab and newline stay): a message's
    subject or body must not be able to move the cursor, retitle the window or hide a link."""
    text = _OSC.sub("", str(text))
    text = _CSI.sub("", text)
    return _CONTROL.sub("", text)


class _Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts, self._skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self._skip += 1
        elif tag in ("br", "p", "div", "li", "tr", "h1", "h2", "h3"):
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style") and self._skip:
            self._skip -= 1

    def handle_data(self, data):
        if not self._skip:
            self.parts.append(data)


def _html_to_text(html: str) -> str:
    parser = _Text()
    parser.feed(html)
    return re.sub(r"\n{3,}", "\n\n", "".join(parser.parts)).strip()


def _parse(raw: bytes):
    return email.message_from_bytes(raw, policy=email.policy.default)


def _attachments(message):
    return [part for part in message.iter_attachments()] if message.is_multipart() else []


def render_message(raw: bytes, *, with_attachments: bool) -> str:
    """The headers that matter, then the text of the body (HTML turned to text)."""
    message = _parse(raw)
    lines = []
    for label in ("From", "To", "Cc", "Date", "Subject"):
        try:
            value = message[label]
        except (ValueError, TypeError):
            value = "(unreadable)"
        if value is not None:
            lines.append(f"{label + ':':<9}{safe(value)}")
    body = message.get_body(preferencelist=("plain", "html"))
    text = ""
    if body is not None:
        try:
            content = body.get_content()
        except (LookupError, ValueError):
            content = body.get_payload(decode=True).decode("utf-8", "replace")
        text = _html_to_text(content) if body.get_content_subtype() == "html" else content
    lines += ["", safe(text).rstrip()]
    if with_attachments:
        found = [f"{safe(Path(p.get_filename() or 'attachment').name)} ({max(1, round(len(p.get_payload(decode=True) or b'') / 1024))} KB)"
                 for p in _attachments(message)]
        if found:
            lines += ["", "attachments: " + ", ".join(found)]
    return "\n".join(lines) + "\n"


def parse_since(text: str, *, now: datetime) -> datetime:
    m = re.fullmatch(r"(\d+)([dh])", text.strip())
    if m:
        amount = int(m.group(1))
        return now - (timedelta(days=amount) if m.group(2) == "d" else timedelta(hours=amount))
    try:
        return datetime.strptime(text.strip(), "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError:
        raise ValueError(f"--since takes 7d, 12h or 2026-10-01: {text!r}") from None


def build_message(*, from_local: str, domain: str, from_name: Optional[str], to: str, subject: str, body: str,
                  attachments: list, in_reply_to: Optional[str], references: Optional[str]) -> bytes:
    """A new message from <from_local>@<domain>. A line break in any header value raises
    ValueError (the stdlib refuses it), so no header can be injected."""
    message = EmailMessage(policy=email.policy.default)
    sender = f"{from_local}@{domain}"
    message["From"] = email.utils.formataddr((from_name, sender)) if from_name else sender
    message["To"] = to
    message["Subject"] = subject
    message["Date"] = email.utils.format_datetime(datetime.now(timezone.utc))
    message["Message-ID"] = f"<{uuid.uuid4().hex}@{domain}>"
    if in_reply_to:
        message["In-Reply-To"] = in_reply_to
    if references:
        message["References"] = references
    message.set_content(body)
    for path in attachments:
        path = Path(path)
        kind, _ = mimetypes.guess_type(path.name)
        maintype, subtype = (kind or "application/octet-stream").split("/", 1)
        message.add_attachment(path.read_bytes(), maintype=maintype, subtype=subtype, filename=path.name)
    return message.as_bytes(policy=email.policy.SMTP)


# -- the system ---------------------------------------------------------------------------------

def _plain(value):
    """DynamoDB numbers come back as Decimal; JSON wants int or float."""
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, dict):
        return {k: _plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_plain(v) for v in value]
    return value


def _conditional_failed(error) -> bool:
    return getattr(error, "response", {}).get("Error", {}).get("Code") == "ConditionalCheckFailedException"


class Mail:
    def __init__(self, settings: Settings, boto, now):
        kw = {"region_name": settings.region} if settings.region else {}
        self.s = settings
        self.table = boto.resource("dynamodb", **kw).Table(settings.table)
        self.s3 = boto.client("s3", **kw)
        self.ses = boto.client("sesv2", **kw)
        self._boto, self._kw = boto, kw
        self.now = now

    def iso(self) -> str:
        return self.now().isoformat(timespec="seconds")

    def scan(self) -> list:
        rows, start = [], None
        while True:
            page = self.table.scan(**({"ExclusiveStartKey": start} if start else {}))
            rows += page.get("Items", [])
            start = page.get("LastEvaluatedKey")
            if not start:
                return rows

    # aliases
    def alias(self, local: str) -> Optional[dict]:
        return self.table.get_item(Key={"pk": f"ALIAS#{local}", "sk": "ALIAS"}, ConsistentRead=True).get("Item")

    def ensure_alias(self, local: str) -> dict:
        now = self.iso()
        row = {"pk": f"ALIAS#{local}", "sk": "ALIAS", "local": local, "state": "forward", "created": now, "first_from": "",
               "last_seen": now, "count": 0, "count_blocked": 0, "protected": local in PROTECTED}
        try:
            self.table.put_item(Item=row, ConditionExpression="attribute_not_exists(pk)")
            return row
        except Exception as error:
            if not _conditional_failed(error):
                raise
            return self.alias(local)

    # messages
    def find(self, ident: str) -> dict:
        rows = self.table.query(IndexName="by-id", KeyConditionExpression="message_id = :id",
                                ExpressionAttributeValues={":id": ident}).get("Items", [])
        if rows:
            return rows[0]
        matches = [r for r in self.scan() if str(r.get("pk", "")).startswith("MSG#") and str(r.get("message_id", "")).startswith(ident)]
        if not matches:
            raise Refused(f"no message {ident}")
        if len(matches) > 1:
            raise Refused(f"ambiguous id {ident}: " + ", ".join(sorted(r["message_id"] for r in matches)))
        return matches[0]

    def raw(self, key: str) -> bytes:
        return self.s3.get_object(Bucket=self.s.bucket, Key=key)["Body"].read()

    def send(self, *, from_local: str, to: str, subject: str, body: str, attachments: list,
             in_reply_to: Optional[str] = None, references: Optional[str] = None) -> dict:
        row = self.alias(from_local)
        if row and row.get("state") == "block":
            raise Refused(f"{from_local} is blocked; unblock it first with: mail.py alias {from_local} --forward")
        row = row or self.ensure_alias(from_local)
        raw = build_message(from_local=from_local, domain=self.s.domain, from_name=row.get("name"), to=to, subject=subject,
                            body=body, attachments=attachments, in_reply_to=in_reply_to, references=references)
        message_id = self.ses.send_email(
            FromEmailAddress=f"{from_local}@{self.s.domain}", Destination={"ToAddresses": [to]},
            Content={"Raw": {"Data": raw}}, ConfigurationSetName=self.s.config_set,
        )["MessageId"]
        key = f"sent/{message_id}"
        self.s3.put_object(Bucket=self.s.bucket, Key=key, Body=raw)
        now = self.now()
        sent = _parse(raw)
        self.table.put_item(Item={
            "pk": f"MSG#{from_local}", "sk": f"{now.isoformat(timespec='seconds')}#{message_id}", "message_id": message_id,
            "alias": from_local, "direction": "out", "from": f"{from_local}@{self.s.domain}", "to": [to], "subject": subject,
            "date": str(sent["Date"]), "header_message_id": str(sent["Message-ID"]), "size": len(raw), "s3_key": key,
            "forwarded": True, "flags": [], "received": now.isoformat(timespec="seconds"),
            "expires": int((now + timedelta(days=365)).timestamp()),
        })
        return {"message_id": message_id, "from": f"{from_local}@{self.s.domain}", "to": to, "subject": subject, "s3_key": key}


# -- the commands -------------------------------------------------------------------------------

def _print(args, data, text_lines):
    if args.json:
        print(json.dumps(_plain(data), indent=2, sort_keys=True))
    else:
        for line in text_lines:
            print(line)


def _table(rows, columns):
    # Every cell goes through safe(): aliases and ids come from strangers' envelope addresses too.
    widths = [max([len(c)] + [len(safe(r.get(k, ""))) for r in rows]) for c, k, _ in columns]
    out = ["  ".join(c.upper().ljust(w) for (c, _, _), w in zip(columns, widths))]
    for r in rows:
        out.append("  ".join(safe(r.get(k, "")).ljust(w)[: m or None] for (_, k, m), w in zip(columns, widths)).rstrip())
    return out


def cmd_aliases(m: Mail, args):
    rows = sorted((_plain(r) for r in m.scan() if r.get("sk") == "ALIAS"), key=lambda r: r.get("local", ""))
    if args.state:
        rows = [r for r in rows if r.get("state") == args.state]
    view = [{**r, "first_from": safe(r.get("first_from", "")), "name": safe(r.get("name", ""))} for r in rows]
    _print(args, rows, _table(view, [("alias", "local", 0), ("state", "state", 0), ("count", "count", 0),
                                     ("blocked", "count_blocked", 0), ("first from", "first_from", 0),
                                     ("last seen", "last_seen", 0), ("name", "name", 0)]))
    return 0


def cmd_alias(m: Mail, args):
    local = args.local.strip().lower()
    state = "block" if args.block else "forward" if args.forward else "archive" if args.archive else None
    if state is None and args.name is None and args.note is None:
        raise Refused("nothing to change: give --block, --forward, --archive, --name or --note")
    row = m.ensure_alias(local)
    if state == "block" and (row.get("protected") or local in PROTECTED):
        raise Refused(f"protected alias: {local}")
    sets, names, values = [], {}, {}
    for attr, key, value in (("state", "#s", state), ("name", "#n", args.name), ("note", "#o", args.note)):
        if value is not None:
            sets.append(f"{key} = :{key[1]}")
            names[key], values[f":{key[1]}"] = attr, value
    row = m.table.update_item(Key={"pk": f"ALIAS#{local}", "sk": "ALIAS"}, UpdateExpression="SET " + ", ".join(sets),
                              ExpressionAttributeNames=names, ExpressionAttributeValues=values, ReturnValues="ALL_NEW")["Attributes"]
    _print(args, row, [safe(f"{local}: {row.get('state')}" + (f", name {row['name']}" if row.get("name") else ""))])
    return 0


def cmd_ls(m: Mail, args):
    since = parse_since(args.since, now=m.now()).isoformat(timespec="seconds") if args.since else None
    if args.alias:
        values = {":pk": f"MSG#{args.alias.lower()}"}
        condition = "pk = :pk"
        if since:
            condition += " AND sk >= :since"
            values[":since"] = since
        rows = m.table.query(KeyConditionExpression=condition, ExpressionAttributeValues=values, ScanIndexForward=False).get("Items", [])
    else:
        rows = [r for r in m.scan() if str(r.get("pk", "")).startswith("MSG#") and (not since or r["sk"] >= since)]
    rows = sorted((_plain(r) for r in rows), key=lambda r: r["sk"], reverse=True)
    if args.spam:
        rows = [r for r in rows if "spam" in (r.get("flags") or [])]
    if args.unforwarded:
        rows = [r for r in rows if r.get("direction") == "in" and not r.get("forwarded")]
    rows = rows[: args.n]
    view = [{
        "id": r["message_id"][:16], "when": r["sk"][:16].replace("T", " "), "alias": r.get("alias", r["pk"][4:]),
        "dir": r.get("direction", ""),
        "who": safe(r.get("from", "") if r.get("direction") == "in" else ", ".join(r.get("to") or [])),
        "subject": safe(r.get("subject", ""))[:60],
        "flags": ",".join((r.get("flags") or []) + ([] if r.get("forwarded") or r.get("direction") == "out" else ["unforwarded"])),
    } for r in rows]
    _print(args, rows, _table(view, [("id", "id", 0), ("when", "when", 0), ("alias", "alias", 0), ("dir", "dir", 0),
                                     ("from/to", "who", 0), ("subject", "subject", 0), ("flags", "flags", 0)]))
    return 0


def _save_attachments(raw: bytes, directory: str) -> list:
    folder = Path(directory)
    folder.mkdir(parents=True, exist_ok=True)
    saved = []
    for part in _attachments(_parse(raw)):
        name = re.sub(r"[^\w.\- ]", "_", Path(part.get_filename() or "attachment").name).lstrip(". ") or "attachment"
        target = folder / name
        stem, suffix, n = target.stem, target.suffix, 1
        while target.exists():
            target, n = folder / f"{stem}-{n}{suffix}", n + 1
        target.write_bytes(part.get_payload(decode=True) or b"")
        saved.append(str(target))
    return saved


def cmd_read(m: Mail, args):
    row = m.find(args.id)
    raw = m.raw(row["s3_key"])
    if args.raw:
        print(safe(raw.decode("utf-8", "replace")))
        return 0
    saved = _save_attachments(raw, args.save_attachments) if args.save_attachments else []
    text = render_message(raw, with_attachments=True)
    if args.json:
        print(json.dumps(_plain({**row, "text": text, "saved": saved}), indent=2, sort_keys=True))
    else:
        print(safe(f"id:      {row['message_id']}  ({row.get('direction')}, alias {row.get('alias')})"))
        print(text, end="")
        for path in saved:
            print(f"saved:   {path}")
    return 0


def _body(args) -> str:
    return Path(args.body_file).read_text() if args.body_file else args.body


def cmd_send(m: Mail, args):
    result = m.send(from_local=args.from_local.strip().lower(), to=args.to, subject=args.subject, body=_body(args),
                    attachments=args.attach or [])
    _print(args, result, [safe(f"sent {result['message_id']} from {result['from']} to {result['to']}")])
    return 0


def cmd_reply(m: Mail, args):
    row = m.find(args.id)
    if row.get("direction") != "in":
        raise Refused(f"{args.id} is not a received message")
    original = _parse(m.raw(row["s3_key"]))
    to = row.get("reply_to") or row.get("from")
    if not to:
        raise Refused(f"{args.id} has no sender to reply to")
    subject = str(original["Subject"] or "")
    if not re.match(r"(?i)\s*re:", subject):
        subject = f"Re: {subject}"
    parent = row.get("header_message_id") or str(original["Message-ID"] or "")
    references = " ".join(x for x in (str(original["References"] or "").strip(), parent) if x) or None
    result = m.send(from_local=row["alias"], to=to, subject=subject, body=_body(args), attachments=args.attach or [],
                    in_reply_to=parent or None, references=references)
    _print(args, result, [safe(f"sent {result['message_id']} from {result['from']} to {result['to']}")])
    return 0


def cmd_forward(m: Mail, args):
    if not m.s.function:
        print("mail: forward needs --function (or $MAIL_FUNCTION): the Lambda that forwards, since this script never holds the owner's address", file=sys.stderr)
        raise SystemExit(2)
    lam = m._boto.client("lambda", **m._kw)
    response = lam.invoke(FunctionName=m.s.function, InvocationType="RequestResponse",
                          Payload=json.dumps({"action": "forward", "message_id": args.id}).encode())
    result = json.loads(response["Payload"].read() or b"{}")
    _print(args, result, [safe(f"{args.id}: ") + ("forwarded" if result.get("sent") else f"not forwarded ({result.get('error')})")])
    return 0 if result.get("sent") else 1


def cmd_status(m: Mail, args):
    account = m.ses.get_account()
    quota = account.get("SendQuota", {})
    rows = m.scan()
    month = m.now().strftime("%Y-%m")
    aliases, counts, forwarded = {}, {"in": 0, "out": 0}, 0
    for r in rows:
        if r.get("sk") == "ALIAS":
            aliases[r.get("state", "forward")] = aliases.get(r.get("state", "forward"), 0) + 1
        elif str(r.get("pk", "")).startswith("MSG#") and str(r.get("sk", "")).startswith(month):
            counts[r.get("direction", "in")] = counts.get(r.get("direction", "in"), 0) + 1
            forwarded += 1 if r.get("direction") == "in" and r.get("forwarded") else 0
    # SES: $0.10 per 1,000 received plus $0.09 per 1,000 256 KB chunks (one for most messages),
    # $0.10 per 1,000 sent (forwards and replies alike). An estimate: the bill is the truth.
    estimate = counts["in"] * 0.00019 + (counts["out"] + forwarded) * 0.0001
    status = {
        "production": bool(account.get("ProductionAccessEnabled")),
        "max_24h": int(quota.get("Max24HourSend", 0)), "sent_last_24h": int(quota.get("SentLast24Hours", 0)),
        "max_rate_per_second": quota.get("MaxSendRate"), "aliases": aliases, "messages_this_month": counts,
        "estimated_cost_this_month_usd": round(estimate, 4),
    }
    _print(args, status, [
        f"SES:      {'production' if status['production'] else 'sandbox (sends only to verified addresses)'}, "
        f"{status['sent_last_24h']} of {status['max_24h']} sends used in the last 24 hours",
        "aliases:  " + (", ".join(f"{n} {s}" for s, n in sorted(aliases.items())) or "none"),
        f"{month}:  {counts['in']} received, {counts['out']} sent, about ${estimate:.4f}",
    ])
    return 0


# -- the command line ---------------------------------------------------------------------------

def _parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="print JSON instead of text")
    for flag in ("table", "bucket", "domain", "function", "config-set", "region"):
        common.add_argument(f"--{flag}", dest=flag.replace("-", "_"))
    parser = argparse.ArgumentParser(prog="mail.py", description="Read, send and manage a domain's alias mail.")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("aliases", parents=[common], help="every alias with its state and counts")
    p.add_argument("--state", choices=STATES)

    p = sub.add_parser("alias", parents=[common], help="block, unblock, archive or name one alias")
    p.add_argument("local")
    group = p.add_mutually_exclusive_group()
    group.add_argument("--block", action="store_true")
    group.add_argument("--forward", action="store_true")
    group.add_argument("--archive", action="store_true")
    p.add_argument("--name")
    p.add_argument("--note")

    p = sub.add_parser("ls", parents=[common], help="list messages, newest first")
    p.add_argument("--alias")
    p.add_argument("--since")
    p.add_argument("--spam", action="store_true")
    p.add_argument("--unforwarded", action="store_true")
    p.add_argument("-n", type=int, default=20)

    p = sub.add_parser("read", parents=[common], help="show one message")
    p.add_argument("id")
    group = p.add_mutually_exclusive_group()
    group.add_argument("--raw", action="store_true")
    group.add_argument("--save-attachments", metavar="DIR")

    for name, helptext in (("send", "send a new message as an alias"), ("reply", "reply to a received message as its alias")):
        p = sub.add_parser(name, parents=[common], help=helptext)
        if name == "send":
            p.add_argument("--from", dest="from_local", required=True, metavar="LOCAL")
            p.add_argument("--to", required=True)
            p.add_argument("--subject", required=True)
        else:
            p.add_argument("id")
        body = p.add_mutually_exclusive_group(required=True)
        body.add_argument("--body")
        body.add_argument("--body-file")
        p.add_argument("--attach", action="append", metavar="FILE")

    p = sub.add_parser("forward", parents=[common], help="forward a stored message to the owner again")
    p.add_argument("id")
    sub.add_parser("status", parents=[common], help="sandbox or production, quota, counts, the month's cost")
    return parser


COMMANDS = {"aliases": cmd_aliases, "alias": cmd_alias, "ls": cmd_ls, "read": cmd_read, "send": cmd_send,
            "reply": cmd_reply, "forward": cmd_forward, "status": cmd_status}


def main(argv=None, *, boto=None, env=None, now=None) -> int:
    import os

    args = _parser().parse_args(argv)
    settings = resolve(args, os.environ if env is None else env)
    if boto is None:
        try:
            import boto3 as boto
        except ImportError:
            print(f"mail: boto3 is not installed: {INSTALL_BOTO3}", file=sys.stderr)
            raise SystemExit(2)
    mail = Mail(settings, boto, now or (lambda: datetime.now(timezone.utc)))
    try:
        return COMMANDS[args.command](mail, args)
    except (Refused, ValueError) as refusal:
        print(f"mail: {refusal}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
