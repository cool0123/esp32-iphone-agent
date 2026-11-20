import base64
import threading

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from hidagent.ops import create_app, public_config, valid_config

DEVICE = {"Authorization": "Bearer device-test-token"}
ADMIN = {"Authorization": "Bearer admin-test-token"}


def client(**kwargs):
    return TestClient(create_app("device-test-token", "admin-test-token", **kwargs), client=("127.0.0.1", 50000))


def test_config_validation_rejects_secrets_and_bad_values():
    with pytest.raises(ValueError, match="unsupported"):
        valid_config({"apiKey": "must-not-be-remote"})
    with pytest.raises(ValueError, match="frameMode"):
        valid_config({"frameMode": "other"})
    with pytest.raises(ValueError, match="JSON object"):
        valid_config({"extraBody": "[]"})
    assert valid_config({"model": "vision-model", "extraBody": "{}"})
    assert public_config({"baseURL": "https://user:pass@example.com/v1?key=secret", "apiKey": "secret"}) == {
        "baseURL": "https://example.com/v1"
    }


def test_admin_auth_and_offline_status():
    with client() as c:
        assert c.get("/health").json() == {"ok": True}
        assert c.get("/api/status").status_code == 401
        r = c.get("/api/status", headers=ADMIN)
        assert r.status_code == 200
        assert r.json()["connected"] is False
        assert c.get("/api/config", headers=ADMIN).status_code == 503
        assert c.post("/api/model-check").status_code == 401
        assert c.post("/api/model-check", headers=ADMIN).status_code == 503


def test_device_auth_and_telemetry():
    with client() as c:
        with pytest.raises(WebSocketDisconnect) as rejected:
            with c.websocket_connect("/ws/device"):
                pass
        assert rejected.value.code == 4401
        with c.websocket_connect("/ws/device", headers=DEVICE) as ws:
            ws.send_json({"type": "telemetry", "app": {"running": True}, "board": {"gop": 42}})
            r = c.get("/api/status", headers=ADMIN)
            assert r.json()["connected"] is True
            assert r.json()["telemetry"]["board"]["gop"] == 42
        r = c.get("/api/status", headers=ADMIN)
        assert r.json()["connected"] is False


@pytest.mark.parametrize("ok, expected", [(True, 200), (False, 409)])
def test_model_check_relays_phone_result(ok, expected):
    with client() as c:
        with c.websocket_connect("/ws/device", headers=DEVICE) as ws:
            responses = []
            thread = threading.Thread(target=lambda: responses.append(c.post("/api/model-check", headers=ADMIN)))
            thread.start()
            command = ws.receive_json()
            assert command["name"] == "model.check" and command["params"] == {}
            ws.send_json({"type": "result", "id": command["id"], "ok": ok,
                          "data": {"result": "image=red, reasoning_chars=0"}, "error": "LLM HTTP 401"})
            thread.join(timeout=3)
            assert not thread.is_alive()
            assert responses[0].status_code == expected
            if ok:
                assert responses[0].json()["data"]["result"] == "image=red, reasoning_chars=0"
            else:
                assert responses[0].json()["detail"] == "LLM HTTP 401"


TASK_ID = "12" * 16
TASK = {"task_id": TASK_ID, "task": "打开日历"}


def test_task_routes_default_off_and_validate_auth_and_body():
    with client() as c:
        assert c.post("/api/tasks", headers=ADMIN, json=TASK).status_code == 404
    with client(tasks_enabled=True) as c:
        assert c.post("/api/tasks", headers=DEVICE, json=TASK).status_code == 401
        for patch in ({"task_id": "bad"}, {"task": " "}, {"task": "x" * 801}, {"click": [0, 0]}):
            assert c.post("/api/tasks", headers=ADMIN, json={**TASK, **patch}).status_code == 422
        assert c.post("/api/tasks", headers=ADMIN, json=TASK).status_code == 503
        with c.websocket_connect("/ws/device", headers=DEVICE) as ws:
            ws.send_json({"type": "hello", "app": "old"})
            assert c.post("/api/tasks", headers=ADMIN, json=TASK).status_code == 409


def test_task_mode_restricts_lan_administration_and_device_source():
    app = create_app("device-test-token", "admin-test-token", tasks_enabled=True, task_device_ip="192.168.3.16")
    with TestClient(app, client=("192.168.3.18", 50000)) as c:
        assert c.post("/api/tasks", headers={**ADMIN, "X-Forwarded-For": "127.0.0.1"}, json=TASK).status_code == 403
        with pytest.raises(WebSocketDisconnect):
            with c.websocket_connect("/ws/device", headers=DEVICE):
                pytest.fail("unexpected device accepted")


def test_task_submit_status_stop_round_trip_and_reconnect():
    with client(tasks_enabled=True) as c:
        with c.websocket_connect("/ws/device", headers=DEVICE) as ws:
            ws.send_json({"type": "hello", "taskProtocol": "legacy-task-v1"})
            requests = [
                ("POST", "/api/tasks", TASK, "task.submit", "preparing", 202),
                ("GET", f"/api/tasks/{TASK_ID}", {"task_id": TASK_ID}, "task.status", "running", 200),
                ("POST", "/api/tasks/stop", {"task_id": TASK_ID}, "task.stop", "stopping", 200),
            ]
            for method, path, params, name, state, code in requests:
                responses = []
                body = {"json": params} if method == "POST" else {}
                def request_task(responses=responses, method=method, path=path, body=body):
                    responses.append(c.request(method, path, headers=ADMIN, **body))

                thread = threading.Thread(target=request_task)
                thread.start()
                command = ws.receive_json()
                assert (command["name"], command["params"]) == (name, params)
                data = {"task_id": TASK_ID, "state": state}
                ws.send_json({"type": "result", "id": command["id"], "ok": True, "data": data})
                thread.join(timeout=3)
                assert not thread.is_alive()
                assert responses[0].status_code == code
                assert responses[0].json()["data"] == data
        with c.websocket_connect("/ws/device", headers=DEVICE) as ws:
            ws.send_json({"type": "hello", "app": "old"})
            assert c.get(f"/api/tasks/{TASK_ID}", headers=ADMIN).status_code == 409


def test_config_round_trip_and_snapshot():
    with client() as c:
        with c.websocket_connect("/ws/device", headers=DEVICE) as ws:
            ws.send_json({"type": "hello", "device": "test-phone"})

            def get_config():
                response = c.get("/api/config", headers=ADMIN)
                assert response.status_code == 200
                assert response.json()["data"] == {"model": "safe-model", "hasAPIKey": True}

            thread = threading.Thread(target=get_config)
            thread.start()
            command = ws.receive_json()
            assert command["name"] == "config.get"
            ws.send_json({"type": "result", "id": command["id"], "ok": True,
                          "data": {"model": "safe-model", "hasAPIKey": True, "apiKey": "must-not-leak"}})
            thread.join(timeout=3)
            assert not thread.is_alive()

            def set_config():
                response = c.post("/api/config", headers=ADMIN, json={"model": "next-model"})
                assert response.status_code == 200
                assert response.json()["data"]["model"] == "next-model"

            thread = threading.Thread(target=set_config)
            thread.start()
            command = ws.receive_json()
            assert command["name"] == "config.set" and command["params"] == {"model": "next-model"}
            ws.send_json({"type": "result", "id": command["id"], "ok": True,
                          "data": {"model": "next-model", "hasAPIKey": True}})
            thread.join(timeout=3)
            assert not thread.is_alive()

            def get_frame():
                response = c.get("/api/frame.jpg", headers=ADMIN)
                assert response.status_code == 200
                assert response.content == b"\xff\xd8test-jpeg"

            thread = threading.Thread(target=get_frame)
            thread.start()
            command = ws.receive_json()
            assert command["name"] == "snapshot"
            encoded = base64.b64encode(b"\xff\xd8test-jpeg").decode()
            ws.send_json({"type": "result", "id": command["id"], "ok": True, "data": {"jpeg": encoded}})
            thread.join(timeout=3)
            assert not thread.is_alive()
