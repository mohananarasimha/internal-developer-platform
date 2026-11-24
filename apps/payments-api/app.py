"""Minimal stdlib HTTP service for golden-path Kubernetes deployment experiments."""

from __future__ import annotations

import json
import logging
import os
import signal
import threading
from collections import Counter
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("payments-api")

DEFAULT_BIND_HOST = "0.0.0.0"  # noqa: S104 - container workload must bind all interfaces for probes
DEFAULT_PORT = 8080


@dataclass
class AppConfig:
    """Runtime configuration loaded from environment variables."""

    service_name: str = "payments-api"
    version: str = "1.0.0"
    env: str = "local"
    fail_health: bool = False

    @classmethod
    def from_env(cls) -> AppConfig:
        return cls(
            service_name=os.getenv("SERVICE_NAME", "payments-api"),
            version=os.getenv("APP_VERSION", "1.0.0"),
            env=os.getenv("APP_ENV", "local"),
            fail_health=os.getenv("FAIL_HEALTH", "false").strip().lower() == "true",
        )


@dataclass
class MetricsStore:
    """Thread-safe Prometheus request counter store."""

    _lock: threading.Lock = field(default_factory=threading.Lock)
    _requests: Counter[tuple[str, int]] = field(default_factory=Counter)

    def record(self, path: str, status_code: int) -> None:
        with self._lock:
            self._requests[(path, status_code)] += 1

    def render_prometheus(self, healthy: bool) -> str:
        up_value = 1 if healthy else 0
        lines = [
            "# HELP payments_api_up 1 if payments-api is healthy, 0 otherwise.",
            "# TYPE payments_api_up gauge",
            f"payments_api_up {up_value}",
            "# HELP payments_api_requests_total Total HTTP requests handled by payments-api.",
            "# TYPE payments_api_requests_total counter",
        ]
        with self._lock:
            if not self._requests:
                lines.append('payments_api_requests_total{path="/",status="200"} 0')
            else:
                for (path, status_code), count in sorted(self._requests.items()):
                    lines.append(
                        f'payments_api_requests_total{{path="{path}",status="{status_code}"}} '
                        f"{count}"
                    )
        return "\n".join(lines) + "\n"


class PaymentsHTTPServer(ThreadingHTTPServer):
    """ThreadingHTTPServer carrying immutable app config and metrics state."""

    allow_reuse_address = True

    def __init__(
        self,
        server_address: tuple[str, int],
        config: AppConfig,
        metrics: MetricsStore | None = None,
    ) -> None:
        self.app_config = config
        self.metrics = metrics or MetricsStore()
        super().__init__(server_address, PaymentsRequestHandler)


class PaymentsRequestHandler(BaseHTTPRequestHandler):
    """HTTP handler implementing /, /healthz, and /metrics."""

    server: PaymentsHTTPServer

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        logger.info("%s - %s", self.address_string(), format % args)

    def _send_json(self, status: HTTPStatus, payload: dict[str, Any], route: str) -> None:
        body = (json.dumps(payload) + "\n").encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.server.metrics.record(route, status.value)

    def _send_text(self, status: HTTPStatus, text: str, content_type: str, route: str) -> None:
        body = text.encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.server.metrics.record(route, status.value)

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", maxsplit=1)[0]
        cfg = self.server.app_config

        if path == "/":
            self._send_json(
                HTTPStatus.OK,
                {
                    "service": cfg.service_name,
                    "version": cfg.version,
                    "env": cfg.env,
                },
                route="/",
            )
            return

        if path == "/healthz":
            if cfg.fail_health:
                self._send_json(
                    HTTPStatus.SERVICE_UNAVAILABLE,
                    {"status": "unhealthy", "service": cfg.service_name},
                    route="/healthz",
                )
            else:
                self._send_json(
                    HTTPStatus.OK,
                    {"status": "ok", "service": cfg.service_name},
                    route="/healthz",
                )
            return

        if path == "/metrics":
            exposition = self.server.metrics.render_prometheus(healthy=not cfg.fail_health)
            self._send_text(
                HTTPStatus.OK,
                exposition,
                content_type="text/plain; version=0.0.4; charset=utf-8",
                route="/metrics",
            )
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"}, route=path)


def create_server(
    host: str = DEFAULT_BIND_HOST,
    port: int = DEFAULT_PORT,
    config: AppConfig | None = None,
) -> PaymentsHTTPServer:
    """Create a configured PaymentsHTTPServer instance."""
    return PaymentsHTTPServer((host, port), config or AppConfig.from_env())


def main() -> None:
    """Run the HTTP server and shut down cleanly on SIGTERM/SIGINT."""
    host = os.getenv("HOST", DEFAULT_BIND_HOST)
    port = int(os.getenv("PORT", str(DEFAULT_PORT)))
    config = AppConfig.from_env()
    server = create_server(host=host, port=port, config=config)
    shutdown_started = threading.Event()

    def _handle_signal(signum: int, _frame: Any) -> None:
        if shutdown_started.is_set():
            return
        shutdown_started.set()
        sig_name = signal.Signals(signum).name
        logger.info("Received %s; initiating graceful shutdown", sig_name)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    logger.info(
        "Starting %s version=%s env=%s on %s:%d (fail_health=%s)",
        config.service_name,
        config.version,
        config.env,
        host,
        port,
        config.fail_health,
    )
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        logger.info("Server stopped cleanly")


if __name__ == "__main__":
    main()
