import json
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from hidagent.ops import create_app
from hidagent.ops_key import read_key_file

ADMIN = {"Authorization": "Bearer admin-test-token"}
DEVICE = {"Authorization": "Bearer device-test-token"}
KEY = "test-only-rotation-secret"
BODY = {"baseURL": "https://api.example.test/v1", "apiKey": KEY}
PATH = "/api/model/key"


def app(**kw):
    return create_app("device-test-token", "admin-test-token", **kw)


def client(*, enabled=True, host="127.0.0.1", tls=True):
    target = app(tasks_enabled=True, task_device_ip="127.0.0.1", key_rotation_enabled=enabled)
    return TestClient(target, base_url=("https" if tls else "http") + "://testserver", client=(host, 50000))


def test_rotation_is_opt_in_and_requires_local_admin_and_tls():
    with pytest.raises(ValueError):
        app(key_rotation_enabled=True)
    with pytest.raises(ValueError):
        create_app("same", "same", tasks_enabled=True, task_device_ip="127.0.0.1", key_rotation_enabled=True)
    with client(enabled=False) as c:
        assert c.post(PATH, headers=ADMIN, json=BODY).status_code == 404
    with client(host="192.168.3.18") as c:
        assert c.post(PATH, headers={**ADMIN, "X-Forwarded-For": "127.0.0.1"}, json=BODY).status_code == 403
        with pytest.raises(WebSocketDisconnect):
            with c.websocket_connect("wss://testserver/ws/device", headers=DEVICE):
                pytest.fail("unexpected device accepted")
    with client(tls=False) as c:
        assert c.post(PATH, headers={**ADMIN, "X-Forwarded-Proto": "https"}, json=BODY).status_code == 403
        with pytest.raises(WebSocketDisconnect):
            with c.websocket_connect("ws://testserver/ws/device", headers=DEVICE):
                pytest.fail("plaintext device accepted")
    with client() as c:
        assert c.post(PATH, headers=DEVICE, json=BODY).status_code == 401
        assert c.get(PATH, headers=ADMIN).status_code == 405
        assert c.post(PATH, headers=ADMIN, json=BODY).status_code == 503
        with c.websocket_connect("wss://testserver/ws/device", headers=DEVICE) as ws:
            ws.send_json({"type": "hello", "taskProtocol": "legacy-task-v1"})
            assert c.post(PATH, headers=ADMIN, json=BODY).status_code == 409


@pytest.mark.parametrize("patch", [
    {"baseURL": "http://api.example.test"}, {"baseURL": "https://user@api.example.test"},
    {"baseURL": "https://api.example.test/?x=1"}, {"baseURL": "https://api.example.test:bogus"},
    {"apiKey": [KEY]}, {"apiKey": KEY + "\n"}, {"apiKey": " " + KEY}, {KEY: True},
])
def test_rotation_invalid_bodies_never_echo_input(patch):
    with client() as c:
        r = c.post(PATH, headers=ADMIN, json={**BODY, **patch})
        assert r.status_code == 400 and KEY not in r.text


def test_rotation_content_type_and_size_limits():
    with client() as c:
        assert c.post(PATH, headers=ADMIN, content=KEY).status_code == 415
        headers = {**ADMIN, "Content-Type": "application/json"}
        r = c.post(PATH, headers=headers, content=json.dumps({**BODY, "apiKey": KEY * 1000}))
        assert r.status_code == 413 and KEY not in r.text
        r = c.post(PATH, headers=headers, content='{"apiKey":"' + KEY)
        assert r.status_code == 400 and KEY not in r.text


@pytest.mark.parametrize(("reply", "code", "expected"), [
    ({"ok": True, "data": {"updated": True, "apiKey": KEY}}, 200, {"ok": True, "data": {"updated": True}}),
    ({"ok": False, "error": KEY}, 409, {"detail": "key rotation rejected"}),
    ({"ok": False, "error": "app busy or phone locked"}, 409, {"detail": "app busy or phone locked"}),
    ({"ok": True, "data": {"apiKey": KEY}}, 502, {"detail": "key rotation unconfirmed; do not retry automatically"}),
])
def test_rotation_relay_and_filtered_reply(reply, code, expected, caplog):
    with client() as c, c.websocket_connect("wss://testserver/ws/device", headers=DEVICE) as ws:
        ws.send_json({"type": "hello", "keyProtocol": "model-key-v1"})
        with ThreadPoolExecutor(max_workers=1) as pool:
            pending = pool.submit(c.post, PATH, headers=ADMIN, json=BODY)
            cmd = ws.receive_json()
            assert (cmd["name"], cmd["params"]) == ("model.key.rotate", BODY)
            ws.send_json({"type": "result", "id": cmd["id"], **reply})
            r = pending.result(timeout=5)
        assert r.status_code == code and r.json() == expected
        status = c.get("/api/status", headers=ADMIN)
        assert status.json()["model_key_rotation_supported"] is True
        assert KEY not in status.text and KEY not in caplog.text


def test_rotation_rejects_overlap_and_reports_disconnect_without_retry():
    with client() as c, ThreadPoolExecutor(max_workers=1) as pool:
        with c.websocket_connect("wss://testserver/ws/device", headers=DEVICE) as ws:
            ws.send_json({"type": "hello", "keyProtocol": "model-key-v1"})
            pending = pool.submit(c.post, PATH, headers=ADMIN, json=BODY)
            assert ws.receive_json()["name"] == "model.key.rotate"
            r = c.post(PATH, headers=ADMIN, json=BODY)
            assert r.status_code == 409 and r.json() == {"detail": "key rotation already in progress"}
        r = pending.result(timeout=5)
        assert r.status_code == 503 and r.json() == {"detail": "key rotation unconfirmed; do not retry automatically"}
        with c.websocket_connect("wss://testserver/ws/device", headers=DEVICE) as new_ws:
            new_ws.send_json({"type": "hello", "taskProtocol": "legacy-task-v1"})
            assert c.post(PATH, headers=ADMIN, json=BODY).status_code == 409


def test_key_file_refuses_wrong_permissions_and_symlinks(tmp_path):
    p = tmp_path / "key"
    p.write_text(KEY + "\n")
    p.chmod(0o644)
    with pytest.raises(ValueError):
        read_key_file(p)
    p.chmod(0o600)
    assert read_key_file(p) == KEY
    link = tmp_path / "link"
    link.symlink_to(p)
    with pytest.raises(OSError):
        read_key_file(link)
