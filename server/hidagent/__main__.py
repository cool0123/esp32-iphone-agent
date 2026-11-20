import logging
import os
from ipaddress import ip_address

import uvicorn

debug = os.environ.get("HIDAGENT_DEBUG") == "1"
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
logging.getLogger("hidagent").setLevel(logging.DEBUG if debug else logging.INFO)
host = os.environ.get("HOST", "127.0.0.1")
try:
    local = ip_address(host).is_loopback
except ValueError:
    local = host == "localhost"
if not local:
    raise SystemExit("Legacy Web control has no authentication and must bind to loopback")
uvicorn.run("hidagent.app:app", host=host, port=int(os.environ.get("PORT", 8890)))
