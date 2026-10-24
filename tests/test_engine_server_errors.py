import io
import json

from engine.python.basketball_engine import server
from engine.python.basketball_engine.protocol import PROTOCOL_VERSION
from engine.python.basketball_engine.service import EngineService


def test_unexpected_engine_error_is_logged_with_traceback(monkeypatch, capsys):
    def explode(self, command, payload):
        raise RuntimeError("disk gone")

    monkeypatch.setattr(EngineService, "handle", explode)
    request = json.dumps({
        "type": "request",
        "protocol_version": PROTOCOL_VERSION,
        "request_id": "r1",
        "command": "list_candidates",
        "payload": {},
    })
    monkeypatch.setattr("sys.stdin", io.StringIO(request + "\n"))

    server.main()

    captured = capsys.readouterr()
    assert json.loads(captured.out.splitlines()[0])["error"]["code"] == "ENGINE_ERROR"
    assert "[bhe] request list_candidates failed: disk gone" in captured.err
    assert "Traceback" in captured.err
