"""Unit tests for the minimal payments-api HTTP service."""

from __future__ import annotations

import http.client
import importlib.util
import json
import sys
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

APP_PATH = Path(__file__).resolve().parents[1] / "app.py"


def _load_app_module() -> Any:
    spec = importlib.util.spec_from_file_location("payments_api_app", APP_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


app_mod = _load_app_module()


@contextmanager
def running_server(*, fail_health: bool = False) -> Iterator[int]:
    config = app_mod.AppConfig(
        service_name="payments-api",
        version="1.0.0",
        env="test",
        fail_health=fail_health,
    )
    server = app_mod.create_server(host="127.0.0.1", port=0, config=config)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
    thread.start()
    try:
        yield port
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def _get(port: int, path: str) -> tuple[int, str, str]:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        conn.request("GET", path)
        resp = conn.getresponse()
        body = resp.read().decode("utf-8")
        content_type = resp.getheader("Content-Type", "")
        return resp.status, content_type, body
    finally:
        conn.close()


def test_root_healthz_and_metrics_healthy() -> None:
    with running_server(fail_health=False) as port:
        status, ctype, body = _get(port, "/")
        assert status == 200
        assert "application/json" in ctype
        assert json.loads(body) == {
            "service": "payments-api",
            "version": "1.0.0",
            "env": "test",
        }

        h_status, _, h_body = _get(port, "/healthz")
        assert h_status == 200
        assert json.loads(h_body)["status"] == "ok"

        l_status, _, l_body = _get(port, "/livez")
        assert l_status == 200
        assert json.loads(l_body) == {"status": "alive", "service": "payments-api"}

        m_status, m_ctype, m_body = _get(port, "/metrics")
        assert m_status == 200
        assert "text/plain" in m_ctype
        assert "payments_api_up 1" in m_body
        assert 'payments_api_requests_total{path="/",status="200"} 1' in m_body
        assert 'payments_api_requests_total{path="/healthz",status="200"} 1' in m_body
        assert 'payments_api_requests_total{path="/livez",status="200"} 1' in m_body


def test_healthz_returns_503_while_livez_stays_200_when_fail_health_enabled() -> None:
    with running_server(fail_health=True) as port:
        h_status, _, h_body = _get(port, "/healthz")
        assert h_status == 503
        assert json.loads(h_body)["status"] == "unhealthy"

        l_status, _, l_body = _get(port, "/livez")
        assert l_status == 200
        assert json.loads(l_body) == {"status": "alive", "service": "payments-api"}

        m_status, _, m_body = _get(port, "/metrics")
        assert m_status == 200
        assert "payments_api_up 0" in m_body
        assert 'payments_api_requests_total{path="/healthz",status="503"} 1' in m_body
        assert 'payments_api_requests_total{path="/livez",status="200"} 1' in m_body


def test_unknown_route_returns_404() -> None:
    with running_server(fail_health=False) as port:
        status, _, body = _get(port, "/does-not-exist")
        assert status == 404
        assert json.loads(body) == {"error": "not_found"}


def test_work_endpoint_burns_cpu_and_validates_ms() -> None:
    with running_server(fail_health=False) as port:
        status, _, body = _get(port, "/work?ms=20")
        assert status == 200
        payload = json.loads(body)
        assert payload["service"] == "payments-api"
        assert payload["work_ms"] == 20
        assert payload["cpu_ms"] >= 19.0

        bad_type_status, _, bad_type_body = _get(port, "/work?ms=abc")
        assert bad_type_status == 400
        assert json.loads(bad_type_body)["error"] == "invalid_ms"

        for bad_ms in ("0", str(app_mod.MAX_WORK_MS + 1)):
            bad_range_status, _, bad_range_body = _get(port, f"/work?ms={bad_ms}")
            assert bad_range_status == 400
            assert json.loads(bad_range_body)["error"] == "invalid_ms"

        m_status, _, m_body = _get(port, "/metrics")
        assert m_status == 200
        assert 'payments_api_requests_total{path="/work",status="200"} 1' in m_body
        assert 'payments_api_requests_total{path="/work",status="400"} 3' in m_body
