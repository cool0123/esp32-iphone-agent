import base64
import threading

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from hidagent.ops import create_app, public_config, valid_config

DEVICE = {"Authorization": "Bearer device-test-token"}
ADMIN = {"Authorization": "Bearer admin-test-token"}


def client():
    return TestClient(create_app("device-test-token", "admin-test-token"))


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
