"""Authenticated remote-operations relay for the iOS app.

Run separately from the legacy computer-side agent:
  OPS_DEVICE_TOKEN=... OPS_ADMIN_TOKEN=... python -m hidagent.ops

The iPhone makes the outbound WebSocket connection. AI/admin clients use the HTTP API.
No board HID command or model credential is readable through this service.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import os
import secrets
import socket
import time
import uuid
from contextlib import asynccontextmanager
from ipaddress import IPv4Address, IPv4Network
from typing import Annotated, Any
from urllib.parse import urlparse, urlsplit, urlunparse

import uvicorn
from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, ConfigDict, StringConstraints

ALLOWED_CONFIG = {
    "baseURL", "model", "plannerModel", "actorModel", "tokenParam", "extraBody", "agentName", "frameMode",
    "captureSize", "cameraCrop",
}


TaskID = Annotated[str, StringConstraints(min_length=32, max_length=32, pattern=r"^[0-9a-f]{32}$")]


KEY_PROTOCOL = "model-key-v1"
MAX_ROTATION_BODY = 8192
ROTATION_REJECTIONS = {
    "rotation disabled", "app busy or phone locked", "provider endpoint mismatch", "keychain write failed",
}


def valid_rotation(value: Any) -> bool:
    if not isinstance(value, dict) or set(value) != {"baseURL", "apiKey"}:
        return False
    endpoint, key = value["baseURL"], value["apiKey"]
    if not isinstance(key, str) or not 8 <= len(key) <= 2048 or not all(33 <= ord(c) <= 126 for c in key):
        return False
    if not isinstance(endpoint, str) or not 1 <= len(endpoint) <= 512 or not all(33 <= ord(c) <= 126 for c in endpoint):
        return False
    try:
        u = urlsplit(endpoint)
        return bool(u.scheme == "https" and u.hostname and u.port != 0 and u.username is None
                    and u.password is None and "?" not in endpoint and "#" not in endpoint and "\\" not in endpoint)
    except ValueError:
        return False


class TaskRef(BaseModel):
    model_config = ConfigDict(extra="forbid")

    task_id: TaskID


class TaskStart(TaskRef):
    task: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=800)]


def valid_config(patch: dict[str, str]) -> dict[str, str]:
    unknown = set(patch) - ALLOWED_CONFIG
    if unknown:
        raise ValueError("unsupported config keys: " + ", ".join(sorted(unknown)))
    for key, value in patch.items():
        if len(value) > 4096:
            raise ValueError(f"{key} is too long")
        if key == "baseURL" and value:
            u = urlparse(value)
            if u.scheme not in ("http", "https") or not u.hostname or u.username or u.password:
                raise ValueError("baseURL must be an HTTP(S) URL without credentials")
        elif key == "frameMode" and value not in ("stream", "snap"):
            raise ValueError("frameMode must be stream or snap")
        elif key == "captureSize":
            parts = value.lower().split("x")
            if len(parts) != 2 or not all(p.isdigit() for p in parts):
                raise ValueError("captureSize must be WIDTHxHEIGHT")
            width, height = int(parts[0]), int(parts[1])
            if not 160 <= width <= 1920 or not 160 <= height <= 2560:
                raise ValueError("captureSize is out of range")
        elif key == "cameraCrop":
            try:
                parts = [float(x) for x in value.split(",")]
            except ValueError as e:
                raise ValueError("cameraCrop must be x,y,w,h fractions") from e
            if len(parts) != 4 or not all(0 <= v <= 1 for v in parts):
                raise ValueError("cameraCrop must be x,y,w,h fractions")
            if parts[2] <= 0.05 or parts[3] <= 0.05 or parts[0] + parts[2] > 1.001 or parts[1] + parts[3] > 1.001:
                raise ValueError("cameraCrop is out of range")
        elif key == "tokenParam" and (not value or len(value) > 40):
            raise ValueError("invalid tokenParam")
        elif key == "extraBody":
            try:
                obj = json.loads(value)
            except json.JSONDecodeError as e:
                raise ValueError("extraBody must be a JSON object") from e
            if not isinstance(obj, dict):
                raise ValueError("extraBody must be a JSON object")
        elif key in ("model", "plannerModel", "actorModel") and len(value) > 200:
            raise ValueError(f"{key} is too long")
        elif key == "agentName" and len(value) > 80:
            raise ValueError("agentName is too long")
    return patch


def public_config(data: Any) -> dict[str, Any]:
    if not isinstance(data, dict):
        raise HTTPException(502, "device returned invalid configuration")
    out = {k: v for k, v in data.items() if k in ALLOWED_CONFIG | {"hasAPIKey", "configurationRevision"}}
    if "baseURL" in out:
        try:
            u = urlparse(str(out["baseURL"]))
            host = u.hostname or ""
            if ":" in host:
                host = f"[{host}]"
            if u.port:
                host += f":{u.port}"
            out["baseURL"] = urlunparse((u.scheme, host, u.path, "", "", ""))
        except ValueError:
            out["baseURL"] = ""
    return out


class OpsHub:
    """One phone per service instance; a reconnect replaces the old session."""

    def __init__(self):
        self.ws: WebSocket | None = None
        self.telemetry: dict[str, Any] = {}
        self.last_seen = 0.0
        self.task_protocol = False
        self.key_protocol = False
        self.pending: dict[str, asyncio.Future] = {}
        self.send_lock = asyncio.Lock()
        # Explicit operator opt-in: accept the rotation hello/relay over plain WS on a private LAN.
        self.allow_plain_ws = False

    @property
    def connected(self):
        return self.ws is not None

    async def attach(self, ws: WebSocket):
        old = self.ws
        self.ws = ws
        self.telemetry = {}
        self.last_seen = 0.0
        self.task_protocol = False
        self.key_protocol = False
        if old:
            for future in self.pending.values():
                if not future.done():
                    future.set_exception(RuntimeError("device reconnected"))
            self.pending.clear()
            try:
                await old.close(code=1012, reason="device reconnected")
            except RuntimeError:
                pass  # already closed

    def detach(self, ws: WebSocket):
        if self.ws is not ws:
            return
        self.ws = None
        for future in self.pending.values():
            if not future.done():
                future.set_exception(RuntimeError("device disconnected"))
        self.pending.clear()

    async def receive(self, ws: WebSocket, message: dict[str, Any]):
        if ws is not self.ws:
            return
        self.last_seen = time.time()
        kind = message.get("type")
        if kind == "hello":
            self.task_protocol = message.get("taskProtocol") == "legacy-task-v1"
            self.key_protocol = (ws.url.scheme == "wss" or (self.allow_plain_ws and ws.url.scheme == "ws")) \
                and message.get("keyProtocol") == KEY_PROTOCOL
        if kind in ("hello", "telemetry"):
            self.telemetry = message
        elif kind == "result":
            future = self.pending.pop(str(message.get("id", "")), None)
            if future and not future.done():
                future.set_result(message)

    async def command(self, name: str, params: dict[str, Any] | None = None, timeout: float = 15):
        ws = self.ws
        if not ws:
            raise HTTPException(503, "device is offline")
        if name.startswith("task.") and not self.task_protocol:
            raise HTTPException(409, "connected phone does not support remote tasks")
        if name == "model.key.rotate" and not self.key_protocol:
            raise HTTPException(409, "connected phone does not support secure key rotation")
        request_id = uuid.uuid4().hex
        future = asyncio.get_running_loop().create_future()
        self.pending[request_id] = future
        try:
            async with self.send_lock:
                if ws is not self.ws:
                    raise RuntimeError("device changed before dispatch")
                await ws.send_json({"type": "command", "id": request_id, "name": name, "params": params or {}})
            reply = await asyncio.wait_for(future, timeout)
        except TimeoutError as e:
            raise HTTPException(504, "device command timed out") from e
        except RuntimeError as e:
            raise HTTPException(503, str(e)) from e
        finally:
            self.pending.pop(request_id, None)
        if name == "model.key.rotate":
            if reply.get("ok") is not True:
                detail = reply.get("error")
                if not isinstance(detail, str) or detail not in ROTATION_REJECTIONS:
                    detail = "key rotation rejected"
                raise HTTPException(409, detail)
            data = reply.get("data")
            if not isinstance(data, dict) or data.get("updated") is not True:
                raise HTTPException(502, "unconfirmed key rotation; do not retry automatically")
            return {"updated": True}
        if not reply.get("ok"):
            raise HTTPException(409, str(reply.get("error", "device command failed"))[:300])
        return reply.get("data")


async def result_data(hub: OpsHub, name: str, params: dict[str, Any] | None = None):
    data = await hub.command(name, params)
    return {"ok": True, "data": data}


def create_app(
    device_token: str | None = None, admin_token: str | None = None, *,
    tasks_enabled: bool = False, task_device_ip: str | None = None, key_rotation_enabled: bool = False,
    key_rotation_plain_ws: bool = False,
):
    if key_rotation_plain_ws and not key_rotation_enabled:
        raise ValueError("plaintext rotation requires key rotation")
    if key_rotation_enabled and (not tasks_enabled or not task_device_ip):
        raise ValueError("key rotation requires restricted local task mode")
    device_token = device_token if device_token is not None else os.environ.get("OPS_DEVICE_TOKEN", "")
    admin_token = admin_token if admin_token is not None else os.environ.get("OPS_ADMIN_TOKEN", "")
    if key_rotation_enabled and (not device_token or not admin_token or device_token == admin_token):
        raise ValueError("key rotation requires distinct device and administrator tokens")
    hub = OpsHub()
    hub.allow_plain_ws = key_rotation_plain_ws
    rotation_lock = asyncio.Lock()

    @asynccontextmanager
    async def lifespan(_):
        yield
        if hub.ws:
            await hub.ws.close(code=1001)
            hub.detach(hub.ws)

    app = FastAPI(title="ESP32 Agent remote operations", lifespan=lifespan)

    def admin(request: Request, authorization: str = Header(default="")):
        expected = "Bearer " + admin_token
        if not admin_token or not secrets.compare_digest(authorization.encode(), expected.encode()):
            raise HTTPException(401, "admin authentication required")
        if tasks_enabled and (request.client is None or request.client.host not in {"127.0.0.1", "::1"}):
            raise HTTPException(403, "remote task administration is local only")

    @app.get("/health")
    def health():
        return {"ok": True}

    @app.websocket("/ws/device")
    async def device(ws: WebSocket, authorization: str = Header(default="")):
        expected = "Bearer " + device_token
        if (key_rotation_enabled and ws.url.scheme != "wss" and not key_rotation_plain_ws) or (
            task_device_ip and (ws.client is None or ws.client.host != task_device_ip)
        ) or (
            not device_token or not secrets.compare_digest(authorization.encode(), expected.encode())
        ):
            await ws.close(code=4401)
            return
        await ws.accept()
        await hub.attach(ws)
        try:
            while True:
                message = await ws.receive_json()
                if isinstance(message, dict):
                    await hub.receive(ws, message)
        except WebSocketDisconnect:
            pass
        finally:
            hub.detach(ws)

    @app.get("/api/status", dependencies=[Depends(admin)])
    def status():
        return {"connected": hub.connected, "last_seen": hub.last_seen, "telemetry": hub.telemetry,
                "remote_tasks_supported": hub.connected and hub.task_protocol,
                "model_key_rotation_supported": key_rotation_enabled and hub.connected and hub.key_protocol}

    @app.post("/api/model/key", dependencies=[Depends(admin)])
    async def rotate_model_key(request: Request, response: Response):
        response.headers["Cache-Control"] = "no-store"
        if not key_rotation_enabled:
            raise HTTPException(404, "key rotation disabled")
        if request.url.scheme != "https" and not key_rotation_plain_ws:
            raise HTTPException(403, "key rotation requires direct TLS or the explicit plaintext LAN opt-in")
        if request.headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/json":
            raise HTTPException(415, "expected JSON")
        body = bytearray()
        async for chunk in request.stream():
            if len(body) + len(chunk) > MAX_ROTATION_BODY:
                raise HTTPException(413, "request too large")
            body.extend(chunk)
        try:
            data = json.loads(body)
            if not valid_rotation(data):
                raise ValueError()
        except (ValueError, RecursionError):
            raise HTTPException(400, "invalid key rotation request") from None
        if rotation_lock.locked():
            raise HTTPException(409, "key rotation already in progress")
        async with rotation_lock:
            try:
                result = await hub.command("model.key.rotate", data)
            except HTTPException as e:
                if e.status_code < 500:
                    raise
                raise HTTPException(e.status_code, "key rotation unconfirmed; do not retry automatically") from None
        return {"ok": True, "data": result}

    @app.get("/api/config", dependencies=[Depends(admin)])
    async def config():
        return {"ok": True, "data": public_config(await hub.command("config.get"))}

    @app.post("/api/config", dependencies=[Depends(admin)])
    async def configure(patch: dict[str, str]):
        try:
            patch = valid_config(patch)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        return {"ok": True, "data": public_config(await hub.command("config.set", patch))}

    @app.get("/api/logs", dependencies=[Depends(admin)])
    async def logs():
        return await result_data(hub, "logs.get", {"lines": 100})

    @app.get("/api/frame.jpg", dependencies=[Depends(admin)])
    async def frame():
        data = await hub.command("snapshot", timeout=25)
        try:
            jpeg = base64.b64decode(data.get("jpeg", ""), validate=True)
        except (binascii.Error, AttributeError) as e:
            raise HTTPException(502, "device returned an invalid frame") from e
        if not jpeg.startswith(b"\xff\xd8") or len(jpeg) > 2_000_000:
            raise HTTPException(502, "device returned an invalid frame")
        return Response(jpeg, media_type="image/jpeg", headers={"Cache-Control": "no-store"})

    @app.post("/api/model-check", dependencies=[Depends(admin)])
    async def model_check():
        return {"ok": True, "data": await hub.command("model.check", timeout=100)}

    @app.post("/api/stop", dependencies=[Depends(admin)])
    async def stop():
        return await result_data(hub, "agent.stop")

    def local_tasks():
        if not tasks_enabled:
            raise HTTPException(404, "remote tasks are disabled")

    @app.post("/api/tap", dependencies=[Depends(admin), Depends(local_tasks)])
    async def tap(point: dict):
        """One calibration tap in grid units (0-1000), refused unless the app is idle with a live frame."""
        x, y = point.get("x"), point.get("y")
        if not isinstance(x, int) or not isinstance(y, int) or not (0 <= x <= 1000 and 0 <= y <= 1000):
            raise HTTPException(400, "x and y must be integers between 0 and 1000")
        return await result_data(hub, "cal.tap", {"x": x, "y": y})

    @app.post("/api/swipe", dependencies=[Depends(admin), Depends(local_tasks)])
    async def swipe_for_calibration(body: dict):
        """Run one operator-specified gesture so swipe mechanics can be verified without a model loop."""
        coords = [body.get(k) for k in ("x1", "y1", "x2", "y2")]
        if not all(isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 1000 for v in coords):
            raise HTTPException(400, "x1, y1, x2 and y2 must be integers between 0 and 1000")
        x1, y1, x2, y2 = coords
        return await result_data(hub, "cal.swipe",
                                 {"x1": x1, "y1": y1, "x2": x2, "y2": y2, "hold": body.get("hold") is True})

    @app.post("/api/camera", dependencies=[Depends(admin), Depends(local_tasks)])
    async def camera(body: dict):
        """Start or stop the dock camera that replaces the mirrored screen as the agent's eye."""
        on = body.get("on", True)
        if not isinstance(on, bool):
            raise HTTPException(400, "on must be a boolean")
        return await result_data(hub, "camera", {"on": on})

    @app.post("/api/pointer/span", dependencies=[Depends(admin), Depends(local_tasks)])
    async def pointer_span(body: dict):
        """Pin the pointer span so two candidate calibrations can be compared on the same device."""
        w, h = body.get("w"), body.get("h")
        if not isinstance(w, int) or not isinstance(h, int) or not (100 <= w <= 4000 and 100 <= h <= 4000):
            raise HTTPException(400, "w and h must be integers between 100 and 4000")
        return await result_data(hub, "pointer.setSpan", {"w": w, "h": h})

    @app.post("/api/pointer/calibrate", dependencies=[Depends(admin), Depends(local_tasks)])
    async def pointer_calibrate():
        """Re-solve the pointer span from real measurements on screen."""
        return await result_data(hub, "pointer.calibrate", {})

    @app.post("/api/pointer/measure", dependencies=[Depends(admin), Depends(local_tasks)])
    async def pointer_measure(point: dict):
        """Move to a grid point and report where the pointer actually landed (input-to-pixel mapping)."""
        x, y = point.get("x"), point.get("y")
        if not isinstance(x, int) or not isinstance(y, int) or not (0 <= x <= 1000 and 0 <= y <= 1000):
            raise HTTPException(400, "x and y must be integers between 0 and 1000")
        return await result_data(hub, "pointer.measure", {"x": x, "y": y})

    @app.post("/api/tasks", status_code=202, dependencies=[Depends(admin), Depends(local_tasks)])
    async def submit_task(task: TaskStart):
        return await result_data(hub, "task.submit", task.model_dump())

    @app.get("/api/tasks/{task_id}", dependencies=[Depends(admin), Depends(local_tasks)])
    async def task_status(task_id: TaskID):
        return await result_data(hub, "task.status", {"task_id": task_id})

    @app.post("/api/tasks/stop", dependencies=[Depends(admin), Depends(local_tasks)])
    async def stop_task(task: TaskRef):
        return await result_data(hub, "task.stop", task.model_dump())

    return app


app = create_app()


def main():
    device = os.environ.get("OPS_DEVICE_TOKEN")
    admin = os.environ.get("OPS_ADMIN_TOKEN")
    if not device or not admin or device == admin:
        raise SystemExit("set distinct OPS_DEVICE_TOKEN and OPS_ADMIN_TOKEN")
    host, port = os.environ.get("OPS_HOST", "127.0.0.1"), int(os.environ.get("OPS_PORT", "8787"))
    rotate = os.environ.get("OPS_KEY_ROTATION_ENABLED") == "1"
    rotate_plain = os.environ.get("OPS_KEY_ROTATION_PLAIN_WS") == "1"
    cert, key = os.environ.get("OPS_TLS_CERT"), os.environ.get("OPS_TLS_KEY")
    tasks = os.environ.get("OPS_TASKS_ENABLED") == "1"
    if bool(cert) != bool(key) or (rotate and not rotate_plain and (not tasks or not cert or not key)):
        raise SystemExit("key rotation requires restricted task mode and a direct TLS certificate/key pair")
    if rotate_plain and not tasks:
        raise SystemExit("plaintext key rotation requires restricted task mode")
    tls = {"ssl_certfile": cert, "ssl_keyfile": key}
    if not tasks:
        uvicorn.run(app, host=host, port=port, proxy_headers=False, **tls)
        return
    try:
        lan = IPv4Address(host)
        phone = IPv4Address(os.environ.get("OPS_TASK_DEVICE_IP", ""))
    except ValueError:
        raise SystemExit("set OPS_HOST and OPS_TASK_DEVICE_IP to explicit private LAN IPv4 addresses") from None
    private_lans = tuple(map(IPv4Network, ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")))
    if not any(lan in net and phone in net for net in private_lans) or lan == phone or port != 3233:
        raise SystemExit("task mode requires distinct private LAN addresses and OPS_PORT=3233")
    server = uvicorn.Server(uvicorn.Config(
        create_app(device, admin, tasks_enabled=True, task_device_ip=str(phone), key_rotation_enabled=rotate,
                   key_rotation_plain_ws=rotate_plain),
        proxy_headers=False, access_log=False, ws_max_size=4_000_000, **tls,
    ))
    with socket.socket() as local, socket.socket() as lan_socket:
        for sock, address in ((local, "127.0.0.1"), (lan_socket, str(lan))):
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((address, port))
        server.run(sockets=[local, lan_socket])


if __name__ == "__main__":
    main()
