from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any

import jwt
from fastapi import HTTPException


def _boolean_env(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Principal:
    subject: str
    display_name: str
    scopes: frozenset[str]
    auth_kind: str
    bootstrap_admin: bool = False


class GatewayAuthenticator:
    """Authenticate legacy migration tokens or AuthService RS256 JWTs.

    Authorization intentionally does not live here. AuthService establishes an
    identity (`sub`); each Gateway owns its own entitlements for that identity.
    """

    def __init__(self) -> None:
        self.mode = os.getenv("GATEWAY_AUTH_MODE", "legacy").strip().lower()
        if self.mode not in {"legacy", "hybrid", "oidc"}:
            raise RuntimeError(
                "GATEWAY_AUTH_MODE must be one of: legacy, hybrid, oidc"
            )
        self.legacy_token = os.getenv("GATEWAY_API_TOKEN", "").strip()
        self.legacy_owner = (
            os.getenv("GATEWAY_LEGACY_OWNER_SUB", "legacy-owner").strip()
            or "legacy-owner"
        )
        self.legacy_admin = _boolean_env(
            "GATEWAY_LEGACY_ADMIN", default=self.mode == "legacy"
        )
        self.issuer = os.getenv("GATEWAY_OIDC_ISSUER", "").strip()
        self.audience = os.getenv("GATEWAY_OIDC_AUDIENCE", "").strip()
        self.require_audience = _boolean_env(
            "GATEWAY_OIDC_REQUIRE_AUDIENCE", default=True
        )
        self.jwks_url = os.getenv("GATEWAY_OIDC_JWKS_URL", "").strip()
        if not self.jwks_url and self.issuer:
            self.jwks_url = (
                f"{self.issuer.rstrip('/')}/.well-known/jwks.json"
            )
        self.admin_subjects = frozenset(
            item.strip()
            for item in os.getenv("GATEWAY_ADMIN_SUBS", "").split(",")
            if item.strip()
        )
        self._jwks_client: jwt.PyJWKClient | None = None

    @property
    def oidc_enabled(self) -> bool:
        return self.mode in {"hybrid", "oidc"}

    def status(self) -> dict[str, Any]:
        return {
            "mode": self.mode,
            "oidc_configured": bool(
                self.issuer
                and self.jwks_url
                and (self.audience or not self.require_audience)
            ),
            "issuer": self.issuer or None,
            "audience": self.audience or None,
            "legacy_enabled": self.mode in {"legacy", "hybrid"}
            and bool(self.legacy_token),
        }

    def authenticate(self, authorization: str | None) -> Principal:
        if not authorization or not authorization.lower().startswith("bearer "):
            if self.mode == "legacy" and not self.legacy_token:
                return Principal(
                    subject="local-development",
                    display_name="Local development",
                    scopes=frozenset(),
                    auth_kind="local",
                    bootstrap_admin=True,
                )
            raise HTTPException(
                status_code=401,
                detail="缺少 Authorization: Bearer 登录令牌。",
                headers={"WWW-Authenticate": "Bearer"},
            )

        token = authorization[7:].strip()
        if not token:
            raise HTTPException(status_code=401, detail="登录令牌为空。")

        if (
            self.mode in {"legacy", "hybrid"}
            and self.legacy_token
            and token == self.legacy_token
        ):
            return Principal(
                subject=self.legacy_owner,
                display_name="Legacy Gateway account",
                scopes=frozenset(),
                auth_kind="legacy",
                bootstrap_admin=self.legacy_admin,
            )

        if not self.oidc_enabled:
            raise HTTPException(status_code=401, detail="Gateway Token 无效。")
        if not self.issuer or not self.jwks_url:
            raise HTTPException(
                status_code=503,
                detail="Gateway 尚未配置 AuthService issuer/JWKS。",
            )
        if self.require_audience and not self.audience:
            raise HTTPException(
                status_code=503,
                detail="Gateway 尚未配置 OIDC audience。",
            )

        try:
            if self._jwks_client is None:
                self._jwks_client = jwt.PyJWKClient(
                    self.jwks_url,
                    cache_jwk_set=True,
                    lifespan=300,
                    cache_keys=True,
                    timeout=5,
                )
            signing_key = self._jwks_client.get_signing_key_from_jwt(token)
            decode_options = {"require": ["exp", "iat", "sub", "iss"]}
            kwargs: dict[str, Any] = {
                "algorithms": ["RS256"],
                "issuer": self.issuer,
                "options": decode_options,
            }
            if self.audience:
                kwargs["audience"] = self.audience
            else:
                decode_options["verify_aud"] = False
            claims = jwt.decode(token, signing_key.key, **kwargs)
        except jwt.ExpiredSignatureError as exc:
            raise HTTPException(
                status_code=401,
                detail="登录已过期，请重新登录。",
                headers={"WWW-Authenticate": 'Bearer error="invalid_token"'},
            ) from exc
        except (jwt.PyJWTError, jwt.PyJWKClientError) as exc:
            raise HTTPException(
                status_code=401,
                detail="AuthService 登录令牌无效。",
                headers={"WWW-Authenticate": 'Bearer error="invalid_token"'},
            ) from exc
        except Exception as exc:  # network/DNS errors while refreshing JWKS
            raise HTTPException(
                status_code=503,
                detail="暂时无法校验 AuthService 登录令牌。",
            ) from exc

        subject = str(claims.get("sub") or "").strip()
        if not subject:
            raise HTTPException(status_code=401, detail="登录令牌缺少 sub。")
        raw_scope = claims.get("scope", "")
        if isinstance(raw_scope, str):
            scopes = frozenset(raw_scope.split())
        elif isinstance(raw_scope, list):
            scopes = frozenset(str(item) for item in raw_scope)
        else:
            scopes = frozenset()
        display_name = str(
            claims.get("preferred_username")
            or claims.get("name")
            or subject
        )
        return Principal(
            subject=subject,
            display_name=display_name,
            scopes=scopes,
            auth_kind="oidc",
            bootstrap_admin=subject in self.admin_subjects,
        )
