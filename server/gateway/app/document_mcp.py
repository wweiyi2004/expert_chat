"""Compatibility import for the legacy Gateway package."""

from document_core.mcp_protocol import (
    DocumentMcpBackend,
    DocumentPatchModel,
    McpIdentity,
    StoredDocument,
    create_document_mcp_server,
    mcp_transport_security_from_env,
)
