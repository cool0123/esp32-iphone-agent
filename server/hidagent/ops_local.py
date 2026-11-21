"""Local Ops transport. Never follow redirects (requests may carry credentials)."""

import os
import ssl
from urllib.request import HTTPRedirectHandler, HTTPSHandler, ProxyHandler, build_opener


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def local_ops(*, require_tls=False):
    ca_file = os.environ.get("OPS_TLS_CA")
    # The loopback hop stays local either way; plaintext is for services started with
    # OPS_KEY_ROTATION_PLAIN_WS=1, where only the phone hop lacks TLS.
    tls = bool(ca_file) or os.environ.get("OPS_CLI_TLS") == "1" or (
        require_tls and os.environ.get("OPS_CLI_PLAIN") != "1")
    handlers = [ProxyHandler({}), NoRedirects()]
    if tls:
        handlers.append(HTTPSHandler(context=ssl.create_default_context(cafile=ca_file)))
    return ("https" if tls else "http") + "://127.0.0.1:3233", build_opener(*handlers)
