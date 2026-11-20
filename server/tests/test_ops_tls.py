"""Exercise the rotation relay with real TLS sockets and a simulated phone."""

import asyncio
import inspect
import json
import shutil
import socket
import ssl
import subprocess
import threading
import time

import httpx
import pytest
import uvicorn
from websockets.sync.client import connect

from hidagent.ops import create_app


def test_rotation_over_direct_tls(tmp_path):
    if not shutil.which("openssl"):
        pytest.skip("OpenSSL CLI required to generate a disposable test certificate")
    cert, key = tmp_path / "cert.pem", tmp_path / "key.pem"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
         "-subj", "/CN=local-ops-test", "-addext", "subjectAltName=IP:127.0.0.1",
         "-out", str(cert), "-keyout", str(key)],
        capture_output=True, check=True, timeout=15,
    )
    app = create_app("tls-device-test", "tls-admin-test", tasks_enabled=True,
                     task_device_ip="127.0.0.1", key_rotation_enabled=True)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        address = f"127.0.0.1:{listener.getsockname()[1]}"
        server = uvicorn.Server(uvicorn.Config(
            app, ssl_certfile=str(cert), ssl_keyfile=str(key), proxy_headers=False,
            access_log=False, log_level="warning", timeout_graceful_shutdown=3,
        ))
        worker = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
        worker.start()
        try:
            deadline = time.monotonic() + 5
            while not server.started and worker.is_alive() and time.monotonic() < deadline:
                time.sleep(0.025)
            assert server.started
            with httpx.Client(trust_env=False, timeout=3) as untrusted:
                with pytest.raises(httpx.ConnectError, match="CERTIFICATE_VERIFY_FAILED"):
                    untrusted.get(f"https://{address}/health")
            trust = ssl.create_default_context(cafile=str(cert))
            # websockets 12 uses ssl_context, while newer releases use ssl.
            parameters = inspect.signature(connect).parameters
            tls_arg = "ssl" if "ssl" in parameters else "ssl_context"
            options = {tls_arg: trust, "additional_headers": {"Authorization": "Bearer tls-device-test"}}
            if "proxy" in parameters:
                options["proxy"] = None
            with connect(f"wss://{address}/ws/device", open_timeout=4, close_timeout=2, **options) as device:
                device.send(json.dumps({"type": "hello", "keyProtocol": "model-key-v1"}))
                asyncio.run(assert_relay(address, trust, device))
        finally:
            server.should_exit = True
            worker.join(timeout=8)
            assert not worker.is_alive()


async def assert_relay(address, trust, device):
    secret = "synthetic-tls-rotation-test-only"
    body = {"baseURL": "https://api.example.test/v1", "apiKey": secret}
    async with httpx.AsyncClient(base_url=f"https://{address}", verify=trust, trust_env=False, timeout=5,
                                 headers={"Authorization": "Bearer tls-admin-test"}) as admin:
        # Allow the hello to be processed before the HTTP request races it on another connection.
        for _ in range(20):
            if (await admin.get("/api/status")).json()["model_key_rotation_supported"]:
                break
            await asyncio.sleep(0.05)
        else:
            pytest.fail("rotation capability not advertised over WSS")
        pending = asyncio.create_task(admin.post("/api/model/key", json=body))
        try:
            command = json.loads(await asyncio.to_thread(device.recv, 4))
            assert (command["name"], command["params"]) == ("model.key.rotate", body)
            # Only the explicit acknowledgment may be relayed back, even if a buggy phone echoes the key.
            device.send(json.dumps({"type": "result", "id": command["id"], "ok": True,
                                    "data": {"updated": True, "apiKey": secret}}))
            response = await pending
            assert response.status_code == 200
            assert response.headers["Cache-Control"] == "no-store"
            assert response.json() == {"ok": True, "data": {"updated": True}}
            assert secret not in (await admin.get("/api/status")).text
        finally:
            if not pending.done():
                pending.cancel()
                await asyncio.gather(pending, return_exceptions=True)
