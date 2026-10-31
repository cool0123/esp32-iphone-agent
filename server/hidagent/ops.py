"""Authenticated remote-operations relay for the iOS app.

Run separately from the legacy computer-side agent:
  OPS_DEVICE_TOKEN=... OPS_ADMIN_TOKEN=... python -m hidagent.ops

The iPhone makes the outbound WebSocket connection. AI/admin clients use the HTTP API.
No board HID command or model credential is exposed by this service.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import os
import secrets
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any
from urllib.parse import urlparse, urlunparse

import uvicorn
from fastapi import Depends, FastAPI, Header, HTTPException, Response, WebSocket, WebSocketDisconnect

ALLOWED_CONFIG = {
    "baseURL", "model", "plannerModel", "actorModel", "tokenParam", "extraBody", "agentName", "frameMode",
}


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
        self.pending: dict[str, asyncio.Future] = {}
        self.send_lock = asyncio.Lock()

    @property
    def connected(self):
        return self.ws is not None

    async def attach(self, ws: WebSocket):
        old = self.ws
        self.ws = ws
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

    async def receive(self, message: dict[str, Any]):
        self.last_seen = time.time()
        kind = message.get("type")
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
        request_id = uuid.uuid4().hex
        future = asyncio.get_running_loop().create_future()
        self.pending[request_id] = future
        try:
            async with self.send_lock:
                await ws.send_json({"type": "command", "id": request_id, "name": name, "params": params or {}})
            reply = await asyncio.wait_for(future, timeout)
        except TimeoutError as e:
            raise HTTPException(504, "device command timed out") from e
        except RuntimeError as e:
            raise HTTPException(503, str(e)) from e
        finally:
            self.pending.pop(request_id, None)
        if not reply.get("ok"):
            raise HTTPException(409, str(reply.get("error", "device command failed"))[:300])
        return reply.get("data")


async def result_data(hub: OpsHub, name: str, params: dict[str, Any] | None = None):
    data = await hub.command(name, params)
    return {"ok": True, "data": data}


def create_app(device_token: str | None = None, admin_token: str | None = None):
    device_token = device_token if device_token is not None else os.environ.get("OPS_DEVICE_TOKEN", "")
    admin_token = admin_token if admin_token is not None else os.environ.get("OPS_ADMIN_TOKEN", "")
    hub = OpsHub()

    @asynccontextmanager
    async def lifespan(_):
        yield
        if hub.ws:
            await hub.ws.close(code=1001)
            hub.detach(hub.ws)

    app = FastAPI(title="ESP32 Agent remote operations", lifespan=lifespan)

    def admin(authorization: str = Header(default="")):
        expected = "Bearer " + admin_token
        if not admin_token or not secrets.compare_digest(authorization, expected):
            raise HTTPException(401, "admin authentication required")

    @app.get("/health")
    def health():
        return {"ok": True}

    @app.websocket("/ws/device")
    async def device(ws: WebSocket, authorization: str = Header(default="")):
        expected = "Bearer " + device_token
        if not device_token or not secrets.compare_digest(authorization, expected):
            await ws.close(code=4401)
            return
        await ws.accept()
        await hub.attach(ws)
        try:
            while True:
                message = await ws.receive_json()
                if isinstance(message, dict):
                    await hub.receive(message)
        except WebSocketDisconnect:
            pass
        finally:
            hub.detach(ws)

    @app.get("/api/status", dependencies=[Depends(admin)])
    def status():
        return {"connected": hub.connected, "last_seen": hub.last_seen, "telemetry": hub.telemetry}

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

    return app


app = create_app()

if __name__ == "__main__":
    if not os.environ.get("OPS_DEVICE_TOKEN") or not os.environ.get("OPS_ADMIN_TOKEN"):
        raise SystemExit("set OPS_DEVICE_TOKEN and OPS_ADMIN_TOKEN in the environment")
    uvicorn.run(app, host=os.environ.get("OPS_HOST", "127.0.0.1"), port=int(os.environ.get("OPS_PORT", "8787")))
