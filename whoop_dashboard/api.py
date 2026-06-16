"""Thin WHOOP v2 REST client: auth header injection, pagination, rate-limit backoff.

Rate limits (per WHOOP docs): 100 req/min, 10,000 req/day. On 429 we honour the
X-RateLimit-Reset header (seconds) before retrying.
"""

from __future__ import annotations

import time
from typing import Iterator, Optional

import httpx

from . import auth, config


class WhoopAPIError(RuntimeError):
    pass


class WhoopClient:
    def __init__(self, polite_delay: float = 0.0):
        # polite_delay: optional pause between successful requests during big backfills.
        self._polite_delay = polite_delay
        self._client = httpx.Client(
            base_url=config.API_BASE,
            headers={"User-Agent": config.USER_AGENT, "Accept": "application/json"},
            timeout=30,
        )

    def close(self) -> None:
        self._client.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # --- core request with retry/backoff -----------------------------------

    def _get(self, path: str, params: Optional[dict] = None) -> dict:
        max_attempts = 6
        refreshed_on_401 = False
        for attempt in range(max_attempts):
            token = auth.get_access_token()
            resp = self._client.get(
                path, params=params, headers={"Authorization": f"Bearer {token}"}
            )

            if resp.status_code == 200:
                if self._polite_delay:
                    time.sleep(self._polite_delay)
                return resp.json()

            if resp.status_code == 401 and not refreshed_on_401:
                # Access token rejected — force one refresh and retry.
                refreshed_on_401 = True
                try:
                    auth.refresh_now()
                except auth.AuthError as e:
                    raise WhoopAPIError(str(e))
                continue

            if resp.status_code == 429:
                wait = _retry_after(resp)
                time.sleep(wait)
                continue

            if resp.status_code in (500, 502, 503, 504):
                time.sleep(min(2 ** attempt, 30))
                continue

            raise WhoopAPIError(
                f"GET {path} failed ({resp.status_code}): {resp.text[:300]}"
            )

        raise WhoopAPIError(f"GET {path} failed after {max_attempts} attempts (rate limit / server errors).")

    # --- pagination --------------------------------------------------------

    def _paginate(self, path: str, params: Optional[dict] = None) -> Iterator[dict]:
        params = dict(params or {})
        params.setdefault("limit", 25)  # WHOOP max page size
        while True:
            page = self._get(path, params)
            for rec in page.get("records", []):
                yield rec
            next_token = page.get("next_token")
            if not next_token:
                return
            params["nextToken"] = next_token  # request param is camelCase

    def _collect(self, path: str, start: Optional[str], end: Optional[str]) -> list[dict]:
        params: dict = {}
        if start:
            params["start"] = start
        if end:
            params["end"] = end
        return list(self._paginate(path, params))

    def paginate(self, path: str, start: Optional[str] = None, end: Optional[str] = None):
        """Public generator: yield records across all pages so the caller can persist
        them incrementally (a mid-stream failure then keeps already-fetched pages)."""
        params: dict = {}
        if start:
            params["start"] = start
        if end:
            params["end"] = end
        yield from self._paginate(path, params)

    # --- resource helpers --------------------------------------------------

    def profile(self) -> dict:
        return self._get("/user/profile/basic")

    def body_measurement(self) -> dict:
        return self._get("/user/measurement/body")

    def cycles(self, start: Optional[str] = None, end: Optional[str] = None) -> list[dict]:
        return self._collect("/cycle", start, end)

    def recoveries(self, start: Optional[str] = None, end: Optional[str] = None) -> list[dict]:
        return self._collect("/recovery", start, end)

    def sleeps(self, start: Optional[str] = None, end: Optional[str] = None) -> list[dict]:
        return self._collect("/activity/sleep", start, end)

    def workouts(self, start: Optional[str] = None, end: Optional[str] = None) -> list[dict]:
        return self._collect("/activity/workout", start, end)


def _retry_after(resp: httpx.Response) -> float:
    """Seconds to wait before retrying a 429, from WHOOP's headers (fallback: 5s).
    Clamped to [1, 60]s so a bogus or epoch-style header can never hang the sync worker."""
    for header in ("X-RateLimit-Reset", "Retry-After", "x-ratelimit-reset"):
        val = resp.headers.get(header)
        if not val:
            continue
        try:
            n = float(val)
        except ValueError:
            continue
        if n > 1_000_000_000:   # an absolute unix epoch, not a delta — convert to seconds-from-now
            n = n - time.time()
        return max(1.0, min(n, 60.0))
    return 5.0
