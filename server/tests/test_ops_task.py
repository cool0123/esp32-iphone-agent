import io
import json
import sys

from hidagent import ops_task


def test_phone_command_reads_telemetry_without_task_id(monkeypatch, capsys):
    latest = {"task_id": "ab" * 16, "state": "completed", "steps": 2}
    status = {"connected": True, "last_seen": 123.0, "remote_tasks_supported": True,
              "telemetry": {"version": "1.0.19", "taskControl": {"enabled": True, "phone": {
                  "readiness": "ready", "latest": latest}}}}

    class Opener:
        def open(self, request, timeout):
            assert request.full_url == "https://127.0.0.1:3233/api/status"
            assert request.get_method() == "GET"
            assert request.get_header("Authorization") == "Bearer mock-admin-token"
            return io.BytesIO(json.dumps(status).encode())

    monkeypatch.setenv("OPS_ADMIN_TOKEN", "mock-admin-token")
    monkeypatch.setattr(sys, "argv", ["ops_task", "phone"])
    monkeypatch.setattr(ops_task, "local_ops", lambda: ("https://127.0.0.1:3233", Opener()))
    assert ops_task.main() == 0
    result = capsys.readouterr()
    assert not result.err
    assert json.loads(result.out) == {"connected": True, "last_seen": 123.0, "version": "1.0.19",
                                      "tasks_supported": True, "tasks_enabled": True, "readiness": "ready",
                                      "latest": latest}


def test_phone_status_does_not_report_cached_readiness_as_live_when_offline():
    status = ops_task.phone_status({"connected": False, "last_seen": 123.0, "remote_tasks_supported": True,
                                    "telemetry": {"version": "1.0.19", "taskControl": {"enabled": True, "phone": {
                                        "readiness": "ready", "latest": {"state": "running"}}}}})
    assert status == {"connected": False, "last_seen": 123.0, "version": None, "tasks_supported": False,
                      "tasks_enabled": None, "readiness": "offline", "latest": None}
