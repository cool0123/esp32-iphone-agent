"""Local CLI for the authenticated iOS 15 task relay (no HID commands)."""

import argparse
import json
import os
import sys
import uuid
from urllib.error import HTTPError, URLError
from urllib.request import Request

from .ops_local import local_ops


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="verb", required=True)
    submit = sub.add_parser("submit")
    submit.add_argument("text")
    submit.add_argument("--id", dest="task_id", default=None)
    for verb in ("status", "stop"):
        sub.add_parser(verb).add_argument("task_id")
    sub.add_parser("phone", help="show connection, readiness and the latest phone task")
    args = parser.parse_args()
    token = os.environ.get("OPS_ADMIN_TOKEN")
    if not token:
        parser.exit(2, "Set OPS_ADMIN_TOKEN in the process environment.\n")
    payload = None
    if args.verb == "phone":
        path = "/api/status"
    else:
        task_id = args.task_id or uuid.uuid4().hex
        if len(task_id) != 32 or any(c not in "0123456789abcdef" for c in task_id):
            parser.error("task ID must be 32 lowercase hexadecimal characters")
        print(f"task_id={task_id}", file=sys.stderr, flush=True)
        body = {"task_id": task_id}
        if args.verb == "submit":
            body["task"] = args.text
        path = "/api/tasks" + {"submit": "", "status": "/" + task_id, "stop": "/stop"}[args.verb]
        if args.verb != "status":
            payload = json.dumps(body).encode()
    try:
        base, opener = local_ops()
        request = Request(base + path, data=payload,
                          headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        with opener.open(request, timeout=20) as response:
            reply = json.load(response)
            data = phone_status(reply) if args.verb == "phone" else reply["data"]
            print(json.dumps(data, ensure_ascii=False))
    except HTTPError as error:
        try:
            detail = json.load(error).get("detail")
        except ValueError:
            detail = None
        print(f"HTTP {error.code}: {detail if isinstance(detail, str) else 'request rejected'}", file=sys.stderr)
        if args.verb == "submit" and error.code >= 500:
            print("Delivery not confirmed; check this task ID before any retry.", file=sys.stderr)
        return 1
    except (URLError, TimeoutError, OSError):
        print("Local relay unavailable or timed out; do not resubmit automatically.", file=sys.stderr)
        return 1
    return 0


def object_or_empty(value):
    return value if isinstance(value, dict) else {}


def phone_status(reply):
    connected = reply.get("connected") is True
    telemetry = object_or_empty(reply.get("telemetry"))
    control = object_or_empty(telemetry.get("taskControl")) if connected else {}
    phone = object_or_empty(control.get("phone"))
    return {
        "connected": connected,
        "last_seen": reply.get("last_seen"),
        "version": telemetry.get("version") if connected else None,
        "tasks_supported": reply.get("remote_tasks_supported") is True and connected,
        "tasks_enabled": control.get("enabled") if isinstance(control.get("enabled"), bool) else None,
        "readiness": phone.get("readiness") if connected else "offline",
        "latest": phone.get("latest"),
    }


if __name__ == "__main__":
    sys.exit(main())
