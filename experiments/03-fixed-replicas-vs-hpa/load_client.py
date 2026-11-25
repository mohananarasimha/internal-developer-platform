"""Open-loop HTTP load generator (Python stdlib only) for Experiment 03.

Requests are scheduled at a fixed arrival rate regardless of how fast responses
come back. Each request runs on its own thread so a slow server never delays the
next arrival (no coordinated omission). Latency is measured from the *scheduled*
send time. If MAX_INFLIGHT requests are already outstanding, the arrival is
recorded as `client_dropped` instead of being silently delayed.

Configuration via environment variables:
  TARGET_URL, RATE_RPS, DURATION_SEC, INTERVAL_SEC, TIMEOUT_SEC, MAX_INFLIGHT,
  STOP_FILE (optional: stop scheduling early once this path exists; DURATION_SEC is then
  an upper bound)
"""

from __future__ import annotations

import json
import os
import threading
import time
import urllib.error
import urllib.request
from collections import Counter, defaultdict

URL = os.environ["TARGET_URL"]
RATE = float(os.environ.get("RATE_RPS", "50"))
DURATION = float(os.environ.get("DURATION_SEC", "60"))
INTERVAL = float(os.environ.get("INTERVAL_SEC", "10"))
TIMEOUT = float(os.environ.get("TIMEOUT_SEC", "5"))
MAX_INFLIGHT = int(os.environ.get("MAX_INFLIGHT", "600"))
STOP_FILE = os.environ.get("STOP_FILE", "")

lock = threading.Lock()
results: list[tuple[float, float | None, str]] = []
inflight = 0


def classify(exc: BaseException) -> str:
    if isinstance(exc, urllib.error.HTTPError):
        return f"http_{exc.code}"
    reason = getattr(exc, "reason", exc)
    if isinstance(exc, TimeoutError) or isinstance(reason, TimeoutError):
        return "timeout"
    return "conn_err"


def send(sched_mono: float, offset: float) -> None:
    global inflight
    outcome = "ok"
    try:
        with urllib.request.urlopen(URL, timeout=TIMEOUT) as resp:  # noqa: S310 - fixed in-cluster URL
            resp.read()
            if not 200 <= resp.status < 300:
                outcome = f"http_{resp.status}"
    except Exception as exc:  # noqa: BLE001 - every failure is a data point
        outcome = classify(exc)
    latency = time.monotonic() - sched_mono
    with lock:
        results.append((offset, latency, outcome))
        inflight -= 1


def pct(sorted_vals: list[float], p: float) -> float | None:
    if not sorted_vals:
        return None
    idx = min(len(sorted_vals) - 1, max(0, int(round(p / 100.0 * len(sorted_vals) + 0.5)) - 1))
    return sorted_vals[idx]


def summarize(rows: list[tuple[float, float | None, str]]) -> dict[str, object]:
    ok = sorted(lat * 1000.0 for _, lat, out in rows if out == "ok" and lat is not None)
    outcomes = Counter(out for _, _, out in rows)
    sent = len(rows)
    errors = sent - outcomes.get("ok", 0)

    def fmt(v: float | None) -> float | None:
        return None if v is None else round(v, 1)

    return {
        "sent": sent,
        "ok": outcomes.get("ok", 0),
        "err": errors,
        "err_pct": round(100.0 * errors / sent, 2) if sent else 0.0,
        "p50_ms": fmt(pct(ok, 50)),
        "p95_ms": fmt(pct(ok, 95)),
        "p99_ms": fmt(pct(ok, 99)),
        "outcomes": dict(sorted(outcomes.items())),
    }


def main() -> None:
    global inflight
    print(
        f"CONFIG url={URL} rate_rps={RATE} duration_sec={DURATION} interval_sec={INTERVAL} "
        f"timeout_sec={TIMEOUT} max_inflight={MAX_INFLIGHT}",
        flush=True,
    )
    start_epoch = time.time()
    start = time.monotonic()
    print(f"LOAD_START epoch={start_epoch:.3f}", flush=True)
    n = 0
    max_seen_inflight = 0
    next_stop_check = 0.0
    while True:
        offset = n / RATE
        if offset >= DURATION:
            break
        if STOP_FILE and offset >= next_stop_check:
            next_stop_check = offset + 1.0
            if os.path.exists(STOP_FILE):
                break
        target = start + offset
        delay = target - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        with lock:
            admit = inflight < MAX_INFLIGHT
            if admit:
                inflight += 1
                max_seen_inflight = max(max_seen_inflight, inflight)
            else:
                results.append((offset, None, "client_dropped"))
        if admit:
            threading.Thread(target=send, args=(target, offset), daemon=True).start()
        n += 1
    elapsed = min(DURATION, n / RATE)
    print(f"LOAD_END epoch={time.time():.3f} scheduled={n} elapsed_sec={elapsed:.1f}", flush=True)

    drain_deadline = time.monotonic() + 2 * TIMEOUT + 5
    while time.monotonic() < drain_deadline:
        with lock:
            if inflight == 0:
                break
        time.sleep(0.2)
    with lock:
        rows = list(results)
        leftover = inflight
    print(f"DRAINED leftover_inflight={leftover} max_inflight_seen={max_seen_inflight}", flush=True)

    buckets: dict[int, list[tuple[float, float | None, str]]] = defaultdict(list)
    for row in rows:
        buckets[int(row[0] // INTERVAL)].append(row)
    for b in sorted(buckets):
        s = summarize(buckets[b])
        lo, hi = int(b * INTERVAL), int((b + 1) * INTERVAL)
        print(f"INTERVAL t={lo:>4}-{hi:<4}s " + json.dumps(s), flush=True)
    overall = summarize(rows)
    overall["goodput_rps"] = round(overall["ok"] / elapsed, 2) if elapsed else 0.0
    print("SUMMARY " + json.dumps(overall), flush=True)


if __name__ == "__main__":
    main()
