"""Unit tests for mail.py, on in-memory stand-ins for DynamoDB, S3, SES and Lambda.
Run from the skill's folder: python3 -B -m unittest discover -s scripts/tests"""

import argparse
import email
import email.policy
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import mail  # noqa: E402
from mail import build_message, main, parse_since, render_message, resolve  # noqa: E402

NOW = datetime(2026, 10, 30, 12, 0, 0, tzinfo=timezone.utc)
ENV = {"MAIL_TABLE": "mail", "MAIL_BUCKET": "example-com-mail", "MAIL_DOMAIN": "example.com", "MAIL_FUNCTION": "mail-inbound"}

PLAIN = (b'From: "Ada Example" <ada@example.org>\nTo: hello@example.com\nSubject: Hello there\n'
         b"Date: Fri, 30 Oct 2026 12:00:00 +0000\nMessage-ID: <m1@example.org>\nReferences: <root@example.org>\n"
         b"Reply-To: ada-replies@example.org\nContent-Type: text/plain; charset=utf-8\n\nHi,\n\nIt works.\n")
HTML_ONLY = (b"From: bob@example.org\nTo: hello@example.com\nSubject: Html\nMessage-ID: <h1@example.org>\n"
             b"Content-Type: text/html; charset=utf-8\n\n<p>Hello <b>bold</b></p><script>x()</script>\n")
WITH_PDF = (b"From: bob@example.org\nTo: hello@example.com\nSubject: Report\nMessage-ID: <p1@example.org>\n"
            b'MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary="B"\n\n--B\nContent-Type: text/plain\n\nSee attached.\n'
            b'--B\nContent-Type: application/pdf\nContent-Disposition: attachment; filename="../../report.pdf"\n'
            b"Content-Transfer-Encoding: base64\n\n" + __import__("base64").b64encode(b"%PDF" + b"x" * 2044) + b"\n--B--\n")


def parse(raw):
    return email.message_from_bytes(raw, policy=email.policy.default)


class FakeTable:
    def __init__(self):
        self.items = {}

    def seed(self, item):
        self.items[(item["pk"], item["sk"])] = dict(item)

    def get_item(self, Key, ConsistentRead=False):
        item = self.items.get((Key["pk"], Key["sk"]))
        return {"Item": dict(item)} if item else {}

    def put_item(self, Item, ConditionExpression=None):
        key = (Item["pk"], Item["sk"])
        if ConditionExpression == "attribute_not_exists(pk)" and key in self.items:
            error = Exception("ConditionalCheckFailedException")
            error.response = {"Error": {"Code": "ConditionalCheckFailedException"}}
            raise error
        self.items[key] = dict(Item)

    def update_item(self, Key, UpdateExpression, ExpressionAttributeValues, ExpressionAttributeNames=None, ReturnValues=None):
        names = ExpressionAttributeNames or {}
        item = self.items[(Key["pk"], Key["sk"])]
        assert UpdateExpression.startswith("SET "), UpdateExpression
        for part in UpdateExpression[4:].split(","):
            attr, value = [x.strip() for x in part.split("=")]
            item[names.get(attr, attr)] = ExpressionAttributeValues[value]
        return {"Attributes": dict(item)}

    def query(self, KeyConditionExpression, ExpressionAttributeValues, IndexName=None, ScanIndexForward=True, Limit=None, **kw):
        values = ExpressionAttributeValues
        if IndexName == "by-id":
            assert KeyConditionExpression == "message_id = :id"
            rows = [i for i in self.items.values() if i.get("message_id") == values[":id"]]
        else:
            rows = [i for i in self.items.values() if i["pk"] == values[":pk"]]
            if ":since" in values:
                rows = [r for r in rows if r["sk"] >= values[":since"]]
        rows = sorted(rows, key=lambda r: r["sk"], reverse=not ScanIndexForward)
        return {"Items": [dict(r) for r in rows[:Limit] if Limit is None or True][: Limit or None]}

    def scan(self, **kw):
        return {"Items": [dict(i) for i in self.items.values()]}


class FakeS3:
    def __init__(self):
        self.objects = {}

    def get_object(self, Bucket, Key):
        return {"Body": io.BytesIO(self.objects[Key])}

    def put_object(self, Bucket, Key, Body):
        self.objects[Key] = Body


class FakeSES:
    def __init__(self):
        self.calls, self.message_ids = [], []

    def send_email(self, **kw):
        self.calls.append(kw)
        self.message_ids.append(f"0100-out-{len(self.calls)}")
        return {"MessageId": self.message_ids[-1]}

    def get_account(self):
        return {"ProductionAccessEnabled": False, "SendQuota": {"Max24HourSend": 200.0, "MaxSendRate": 1.0, "SentLast24Hours": 3.0}}


class FakeLambda:
    def __init__(self):
        self.calls = []

    def invoke(self, **kw):
        self.calls.append(kw)
        return {"Payload": io.BytesIO(json.dumps({"message_id": "abc123", "sent": True, "error": None}).encode())}


class FakeBoto:
    def __init__(self):
        self.table, self.s3, self.ses, self.lam = FakeTable(), FakeS3(), FakeSES(), FakeLambda()

    def resource(self, name, **kw):
        assert name == "dynamodb"
        boto = self

        class Resource:
            def Table(self, table_name):
                return boto.table

        return Resource()

    def client(self, name, **kw):
        return {"s3": self.s3, "sesv2": self.ses, "lambda": self.lam}[name]


def run(argv, fake, env=ENV):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = main(argv, boto=fake, env=env, now=lambda: NOW)
    return code, out.getvalue(), err.getvalue()


def stored(fake, message_id, alias, raw, direction="in", **extra):
    fake.s3.objects[f"raw/{message_id}"] = raw
    msg = parse(raw)
    fake.table.seed({"pk": f"MSG#{alias}", "sk": f"2026-10-30T11:00:00+00:00#{message_id}", "message_id": message_id,
                     "alias": alias, "direction": direction, "s3_key": f"raw/{message_id}", "subject": str(msg["Subject"]),
                     "from": "ada@example.org", "reply_to": extra.pop("reply_to", None) or "ada-replies@example.org",
                     "header_message_id": str(msg["Message-ID"]), "forwarded": True, "flags": [], **extra})


class Resolve(unittest.TestCase):
    def ns(self, **kw):
        return argparse.Namespace(**{"table": None, "bucket": None, "domain": None, "function": None, "config_set": None,
                                     "region": None, **kw})

    def test_env_fills_flags(self):
        s = resolve(self.ns(), ENV)
        self.assertEqual((s.table, s.bucket, s.domain, s.function, s.config_set), ("mail", "example-com-mail", "example.com", "mail-inbound", "mail"))

    def test_flags_win(self):
        self.assertEqual(resolve(self.ns(table="other"), ENV).table, "other")

    def test_missing_table_exits_2_naming_both(self):
        err = io.StringIO()
        with redirect_stderr(err), self.assertRaises(SystemExit) as cm:
            resolve(self.ns(bucket="b", domain="d"), {})
        self.assertEqual(cm.exception.code, 2)
        self.assertIn("--table", err.getvalue())
        self.assertIn("MAIL_TABLE", err.getvalue())


class BuildMessage(unittest.TestCase):
    def build(self, **kw):
        args = dict(from_local="tips", domain="example.com", from_name=None, to="ada@example.org", subject="Hi",
                    body="Thanks!", attachments=[], in_reply_to=None, references=None)
        return parse(build_message(**{**args, **kw}))

    def test_plain_from_alias(self):
        m = self.build()
        self.assertEqual((m["From"], m["To"], m["Subject"], m.get_content().strip()), ("tips@example.com", "ada@example.org", "Hi", "Thanks!"))
        self.assertTrue(m["Message-ID"].endswith("@example.com>"))
        self.assertTrue(m["Date"].endswith("+0000"))

    def test_reply_threads(self):
        m = self.build(from_name="Tips", to="a@b.c", subject="Re: x", body="y", in_reply_to="<1@b.c>", references="<0@b.c> <1@b.c>")
        self.assertEqual((m["From"], m["In-Reply-To"], m["References"]), ("Tips <tips@example.com>", "<1@b.c>", "<0@b.c> <1@b.c>"))

    def test_attachment(self):
        m = self.build(attachments=[Path(__file__)])
        self.assertEqual([p.get_filename() for p in m.iter_attachments()], ["test_mail.py"])

    def test_header_injection_through_the_subject_is_refused(self):
        with self.assertRaises(ValueError):
            self.build(subject="Hi\nBcc: victim@example.org")


class Render(unittest.TestCase):
    def test_plain(self):
        text = render_message(PLAIN, with_attachments=False)
        self.assertIn("From:    Ada Example <ada@example.org>", text)
        self.assertIn("Subject: Hello there", text)
        self.assertIn("It works.", text)

    def test_html_only_becomes_text(self):
        text = render_message(HTML_ONLY, with_attachments=False)
        self.assertIn("Hello bold", text)
        self.assertNotIn("<b>", text)
        self.assertNotIn("x()", text)

    def test_lists_attachments(self):
        self.assertIn("attachments: report.pdf (2 KB)", render_message(WITH_PDF, with_attachments=True))

    def test_terminal_escapes_are_removed(self):
        raw = PLAIN.replace(b"It works.", b"It works.\x1b]8;;http://evil/\x07click\x1b]8;;\x07 \x1b[2J")
        text = render_message(raw, with_attachments=False)
        self.assertNotIn("\x1b", text)
        self.assertNotIn("\x07", text)
        self.assertIn("It works.", text)


class Since(unittest.TestCase):
    def test_forms(self):
        self.assertEqual(parse_since("7d", now=NOW), NOW - timedelta(days=7))
        self.assertEqual(parse_since("12h", now=NOW), NOW - timedelta(hours=12))
        self.assertEqual(parse_since("2026-10-01", now=NOW), datetime(2026, 10, 1, tzinfo=timezone.utc))

    def test_bad_form(self):
        with self.assertRaises(ValueError):
            parse_since("soon", now=NOW)


class Commands(unittest.TestCase):
    def setUp(self):
        self.fake = FakeBoto()

    def test_send_writes_sent_and_index(self):
        code, out, _ = run(["send", "--from", "tips", "--to", "ada@example.org", "--subject", "Hi", "--body", "Thanks", "--json"], self.fake)
        self.assertEqual(code, 0)
        call = self.fake.ses.calls[0]
        self.assertEqual((call["FromEmailAddress"], call["Destination"]["ToAddresses"], call["ConfigurationSetName"]),
                         ("tips@example.com", ["ada@example.org"], "mail"))
        mid = self.fake.ses.message_ids[0]
        self.assertIn(f"sent/{mid}", self.fake.s3.objects)
        rows = [r for (pk, _), r in self.fake.table.items.items() if pk == "MSG#tips"]
        self.assertEqual((rows[0]["direction"], rows[0]["message_id"], rows[0]["to"]), ("out", mid, ["ada@example.org"]))
        self.assertIn("ALIAS#tips", [pk for pk, _ in self.fake.table.items])  # sending creates the alias
        self.assertEqual(json.loads(out)["message_id"], mid)

    def test_send_as_a_blocked_alias_is_refused(self):
        self.fake.table.seed({"pk": "ALIAS#spammy", "sk": "ALIAS", "local": "spammy", "state": "block"})
        code, _, err = run(["send", "--from", "spammy", "--to", "a@b.c", "--subject", "x", "--body", "y"], self.fake)
        self.assertEqual(code, 1)
        self.assertIn("spammy is blocked", err)
        self.assertEqual(self.fake.ses.calls, [])

    def test_send_needs_a_body(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
            main(["send", "--from", "tips", "--to", "a@b.c", "--subject", "x"], boto=self.fake, env=ENV)
        self.assertEqual(cm.exception.code, 2)

    def test_reply_threads_to_the_original_sender(self):
        stored(self.fake, "abc123def", "hello", PLAIN)
        code, _, _ = run(["reply", "abc123", "--body", "Glad it works"], self.fake)
        self.assertEqual(code, 0)
        call = self.fake.ses.calls[0]
        self.assertEqual((call["FromEmailAddress"], call["Destination"]["ToAddresses"]), ("hello@example.com", ["ada-replies@example.org"]))
        m = parse(call["Content"]["Raw"]["Data"])
        self.assertEqual((m["Subject"], m["In-Reply-To"], m["References"]), ("Re: Hello there", "<m1@example.org>", "<root@example.org> <m1@example.org>"))

    def test_reply_keeps_an_existing_re(self):
        stored(self.fake, "re1", "hello", PLAIN.replace(b"Subject: Hello there", b"Subject: RE: Hello there"))
        run(["reply", "re1", "--body", "x"], self.fake)
        self.assertEqual(parse(self.fake.ses.calls[0]["Content"]["Raw"]["Data"])["Subject"], "RE: Hello there")

    def test_reply_to_an_outgoing_message_is_refused(self):
        stored(self.fake, "out1", "hello", PLAIN, direction="out")
        code, _, err = run(["reply", "out1", "--body", "x"], self.fake)
        self.assertEqual(code, 1)
        self.assertIn("not a received message", err)

    def test_block_protected_refused(self):
        self.fake.table.seed({"pk": "ALIAS#postmaster", "sk": "ALIAS", "local": "postmaster", "state": "forward", "protected": True})
        code, _, err = run(["alias", "postmaster", "--block"], self.fake)
        self.assertEqual(code, 1)
        self.assertIn("protected alias: postmaster", err)
        self.assertEqual(self.fake.table.items[("ALIAS#postmaster", "ALIAS")]["state"], "forward")

    def test_block_and_name(self):
        code, out, _ = run(["alias", "spammy", "--block", "--name", "Spam", "--json"], self.fake)
        self.assertEqual(code, 0)
        row = self.fake.table.items[("ALIAS#spammy", "ALIAS")]
        self.assertEqual((row["state"], row["name"]), ("block", "Spam"))

    def test_alias_needs_exactly_one_state_or_a_change(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            main(["alias", "x", "--block", "--forward"], boto=self.fake, env=ENV)

    def test_forward_invokes_lambda(self):
        code, _, _ = run(["forward", "abc123"], self.fake)
        self.assertEqual(code, 0)
        call = self.fake.lam.calls[0]
        self.assertEqual((call["FunctionName"], json.loads(call["Payload"])), ("mail-inbound", {"action": "forward", "message_id": "abc123"}))

    def test_forward_without_a_function_exits_2(self):
        env = {k: v for k, v in ENV.items() if k != "MAIL_FUNCTION"}
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
            main(["forward", "abc"], boto=self.fake, env=env)
        self.assertEqual(cm.exception.code, 2)

    def test_read_by_prefix_and_ambiguity(self):
        stored(self.fake, "abc111", "hello", PLAIN)
        stored(self.fake, "abc222", "hello", HTML_ONLY)
        code, out, _ = run(["read", "abc1"], self.fake)
        self.assertEqual(code, 0)
        self.assertIn("It works.", out)
        code, _, err = run(["read", "abc"], self.fake)
        self.assertEqual(code, 1)
        self.assertIn("abc111", err)
        self.assertIn("abc222", err)

    def test_read_saves_attachments_without_path_traversal(self):
        stored(self.fake, "pdf1", "hello", WITH_PDF)
        with tempfile.TemporaryDirectory() as d:
            code, _, _ = run(["read", "pdf1", "--save-attachments", d], self.fake)
            self.assertEqual(code, 0)
            self.assertEqual([p.name for p in Path(d).iterdir()], ["report.pdf"])
            self.assertFalse((Path(d).parent.parent / "report.pdf").exists())

    def test_aliases_and_ls(self):
        self.fake.table.seed({"pk": "ALIAS#hello", "sk": "ALIAS", "local": "hello", "state": "forward", "count": 3,
                              "first_from": "ada@example.org", "last_seen": "2026-10-30T11:00:00+00:00"})
        self.fake.table.seed({"pk": "ALIAS#spammy", "sk": "ALIAS", "local": "spammy", "state": "block", "count": 9})
        stored(self.fake, "m1", "hello", PLAIN)
        stored(self.fake, "m2", "spammy", PLAIN, flags=["spam"], forwarded=False)
        code, out, _ = run(["aliases", "--json"], self.fake)
        self.assertEqual(sorted(r["local"] for r in json.loads(out)), ["hello", "spammy"])
        code, out, _ = run(["aliases", "--state", "block", "--json"], self.fake)
        self.assertEqual([r["local"] for r in json.loads(out)], ["spammy"])
        code, out, _ = run(["ls", "--json"], self.fake)
        self.assertEqual(sorted(r["message_id"] for r in json.loads(out)), ["m1", "m2"])
        code, out, _ = run(["ls", "--spam", "--json"], self.fake)
        self.assertEqual([r["message_id"] for r in json.loads(out)], ["m2"])
        code, out, _ = run(["ls", "--alias", "hello"], self.fake)
        self.assertIn("Hello there", out)
        self.assertNotIn("\x1b", out)

    def test_status(self):
        stored(self.fake, "m1", "hello", PLAIN)
        code, out, _ = run(["status", "--json"], self.fake)
        status = json.loads(out)
        self.assertEqual((status["production"], status["sent_last_24h"], status["messages_this_month"]["in"]), (False, 3, 1))
        self.assertIn("estimated_cost_this_month_usd", status)


class Boto3Missing(unittest.TestCase):
    def test_asks_for_boto3_by_name(self):
        err = io.StringIO()
        real = sys.modules.get("boto3")
        sys.modules["boto3"] = None  # makes `import boto3` raise ImportError
        try:
            with redirect_stderr(err), self.assertRaises(SystemExit) as cm:
                main(["status"], env=ENV)
        finally:
            if real is None:
                del sys.modules["boto3"]
            else:
                sys.modules["boto3"] = real
        self.assertEqual(cm.exception.code, 2)
        self.assertIn("python3 -m pip install --user boto3", err.getvalue())


if __name__ == "__main__":
    unittest.main()
