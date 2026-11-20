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
import socket
import time
import uuid
from contextlib import asynccontextmanager
from ipaddress import IPv4Address, IPv4Network
from typing import Annotated, Any
from urllib.parse import urlparse, urlunparse

import uvicorn
from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, ConfigDict, StringConstraints

ALLOWED_CONFIG = {
    "baseURL", "model", "plannerModel", "actorModel", "tokenParam", "extraBody", "agentName", "frameMode",
}


TaskID = Annotated[str, StringConstraints(min_length=32, max_length=32, pattern=r"^[0-9a-f]{32}$")]


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
        self.pending: dict[str, asyncio.Future] = {}
        self.send_lock = asyncio.Lock()

    @property
    def connected(self):
        return self.ws is not None

    async def attach(self, ws: WebSocket):
        old = self.ws
        self.ws = ws
        self.telemetry = {}
        self.last_seen = 0.0
        self.task_protocol = False
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
        if not reply.get("ok"):
            raise HTTPException(409, str(reply.get("error", "device command failed"))[:300])
        return reply.get("data")


async def result_data(hub: OpsHub, name: str, params: dict[str, Any] | None = None):
    data = await hub.command(name, params)
    return {"ok": True, "data": data}


def create_app(
    device_token: str | None = None, admin_token: str | None = None, *,
    tasks_enabled: bool = False, task_device_ip: str | None = None,
):
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
        if (task_device_ip and (ws.client is None or ws.client.host != task_device_ip)) or (
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
                "remote_tasks_supported": hub.connected and hub.task_protocol}

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
    if os.environ.get("OPS_TASKS_ENABLED") != "1":
        uvicorn.run(app, host=host, port=port, proxy_headers=False)
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
        create_app(device, admin, tasks_enabled=True, task_device_ip=str(phone)),
        proxy_headers=False, access_log=False, ws_max_size=4_000_000,
    ))
    with socket.socket() as local, socket.socket() as lan_socket:
        for sock, address in ((local, "127.0.0.1"), (lan_socket, str(lan))):
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((address, port))
        server.run(sockets=[local, lan_socket])


if __name__ == "__main__":
    main()
