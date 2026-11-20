"""Rotate the phone's model API key over a verified local TLS connection."""

import argparse
import getpass
import json
import os
import stat
import sys
import warnings
from urllib.error import HTTPError
from urllib.request import Request

from .ops import ROTATION_REJECTIONS, valid_rotation
from .ops_local import local_ops

REJECTIONS = ROTATION_REJECTIONS | {
    "connected phone does not support secure key rotation", "key rotation disabled", "key rotation rejected",
    "key rotation already in progress",
}


def read_key_file(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError("key file must be private and owned by the operator")
        raw = handle.read(2051)
        if len(raw) > 2050:
            raise ValueError("key file is too large")
        return raw.decode("ascii").removesuffix("\n").removesuffix("\r")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base_url", help="current HTTPS model endpoint on the phone (not the Ops URL)")
    parser.add_argument("--key-file", help="private regular file holding only the new key (or enter it without echo)")
    args = parser.parse_args()
    token = os.environ.get("OPS_ADMIN_TOKEN")
    if not token:
        parser.exit(2, "Set OPS_ADMIN_TOKEN in the process environment.\n")
    try:
        base, opener = local_ops(require_tls=True)
        if args.key_file:
            key = read_key_file(args.key_file)
        else:
            with warnings.catch_warnings():
                warnings.simplefilter("error", getpass.GetPassWarning)
                key = getpass.getpass("New model API key (hidden): ")
    except (OSError, ValueError, EOFError, KeyboardInterrupt, getpass.GetPassWarning):
        parser.exit(2, "Cannot securely read the key or load TLS trust.\n")
    data = {"baseURL": args.base_url, "apiKey": key}
    if not valid_rotation(data):
        parser.exit(2, "Expected a credential-free HTTPS provider endpoint and a valid key.\n")
    request = Request(base + "/api/model/key", data=json.dumps(data).encode(), headers={
        "Authorization": "Bearer " + token, "Content-Type": "application/json",
    })
    try:
        with opener.open(request, timeout=20) as response:
            result = json.load(response)
            if result == {"ok": True, "data": {"updated": True}}:
                print("Phone confirmed Keychain update. Model connectivity has not been tested.")
                return 0
    except HTTPError as exc:
        if 400 <= exc.code < 500:
            try:
                detail = json.load(exc).get("detail")
            except (ValueError, AttributeError):
                detail = None
            message = detail if isinstance(detail, str) and detail in REJECTIONS else "request rejected"
            print(f"HTTP {exc.code}: {message}", file=sys.stderr)
            return 1
    except (OSError, ValueError):
        pass
    print("No confirmed update. Check the phone or run a model check before retrying.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
