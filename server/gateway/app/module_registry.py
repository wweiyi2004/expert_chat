from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any

from fastapi import APIRouter, FastAPI


@dataclass(frozen=True)
class GatewayCapability:
    """A stable client-visible capability contract."""

    id: str
    version: int = 1
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def manifest(self) -> dict[str, Any]:
        return {"version": self.version, **dict(self.metadata)}


@dataclass(frozen=True)
class GatewayModule:
    """One deployable business module and the capabilities it exports."""

    name: str
    capabilities: tuple[GatewayCapability, ...]
    router: APIRouter | None = None


class GatewayModuleRegistry:
    def __init__(self, modules: tuple[GatewayModule, ...]) -> None:
        self.modules = modules
        ids = [capability.id for module in modules for capability in module.capabilities]
        duplicates = sorted({item for item in ids if ids.count(item) > 1})
        if duplicates:
            raise ValueError(f"Duplicate Gateway capability ids: {', '.join(duplicates)}")

    def install(self, app: FastAPI) -> None:
        for module in self.modules:
            if module.router is not None:
                app.include_router(module.router)

    def manifest(self) -> dict[str, dict[str, Any]]:
        return {
            capability.id: capability.manifest()
            for module in self.modules
            for capability in module.capabilities
        }
