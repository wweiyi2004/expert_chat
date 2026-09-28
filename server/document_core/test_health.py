import asyncio
import httpx
from document_core.health import HealthEndpoint


def test_readiness_and_lifespan_delegation():
    delegated = []

    async def inner(scope, receive, send):
        delegated.append(scope["type"])

    async def exercise():
        app = HealthEndpoint(inner, lambda: None)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as client:
            response = await client.get("/health")
            assert response.json() == {"status": "ok"}

        def broken():
            raise OSError("internal path and credential must not be returned")

        app = HealthEndpoint(inner, broken)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as client:
            response = await client.get("/health")
            assert response.status_code == 503
            assert response.json() == {"status": "unavailable"}
        await app({"type": "lifespan"}, None, None)
        assert delegated == ["lifespan"]

    asyncio.run(exercise())
