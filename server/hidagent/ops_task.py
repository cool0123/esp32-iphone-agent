"""Local CLI for the authenticated iOS 15 task relay (no HID commands)."""

import argparse
import json
import os
import sys
import uuid
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener

BASE = "http://127.0.0.1:3233/api/tasks"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="verb", required=True)
    submit = sub.add_parser("submit")
    submit.add_argument("text")
    submit.add_argument("--id", dest="task_id", default=None)
    for verb in ("status", "stop"):
        sub.add_parser(verb).add_argument("task_id")
    args = parser.parse_args()
    token = os.environ.get("OPS_ADMIN_TOKEN")
    if not token:
        parser.exit(2, "Set OPS_ADMIN_TOKEN in the process environment.\n")
    task_id = args.task_id or uuid.uuid4().hex
    if len(task_id) != 32 or any(c not in "0123456789abcdef" for c in task_id):
        parser.error("task ID must be 32 lowercase hexadecimal characters")
    print(f"task_id={task_id}", file=sys.stderr, flush=True)
    data = {"task_id": task_id}
    if args.verb == "submit":
        data["task"] = args.text
    path = {"submit": "", "status": "/" + task_id, "stop": "/stop"}[args.verb]
    request = Request(BASE + path, data=None if args.verb == "status" else json.dumps(data).encode(),
                      headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with build_opener(ProxyHandler({})).open(request, timeout=20) as response:
            print(json.dumps(json.load(response)["data"], ensure_ascii=False))
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


if __name__ == "__main__":
    sys.exit(main())
