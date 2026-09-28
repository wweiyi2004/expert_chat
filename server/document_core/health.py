"""Unauthenticated liveness/readiness without documents, keys or paths."""

import asyncio
from starlette.responses import JSONResponse


class HealthEndpoint:
    def __init__(self, app, check):
        self.app = app
        self.check = check

    async def __call__(self, scope, receive, send):
        if (
            scope["type"] == "http"
            and scope.get("path") == "/health"
            and scope.get("method") == "GET"
        ):
            try:
                await asyncio.wait_for(asyncio.to_thread(self.check), timeout=2)
                response = JSONResponse({"status": "ok"})
            except Exception:
                response = JSONResponse({"status": "unavailable"}, status_code=503)
            await response(scope, receive, send)
        else:
            await self.app(scope, receive, send)
