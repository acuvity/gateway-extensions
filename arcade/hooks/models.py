from pydantic import BaseModel
from typing import Any


class ToolInfo(BaseModel):
    name: str
    toolkit: str
    version: str | None = None
    metadata: dict[str, Any] | None = None


class Context(BaseModel):
    user_id: str | None = None
    authorization: list[dict[str, Any]] | dict[str, Any] | None = None
    secrets: list[str] | dict[str, Any] | None = None
    metadata: dict[str, Any] | None = None


class HookResponse(BaseModel):
    code: str = "OK"  # OK | CHECK_FAILED | RATE_LIMIT_EXCEEDED
    error_message: str | None = None
    override: dict[str, Any] | None = None


class AccessRequest(BaseModel):
    user_id: str
    toolkits: dict[str, Any]

class PreRequest(BaseModel):
    execution_id: str
    tool: ToolInfo
    inputs: dict[str, Any]
    context: Context | None = None

class PostRequest(BaseModel):
    execution_id: str
    tool: ToolInfo
    inputs: dict[str, Any]
    success: bool
    output: Any = None
    execution_code: str | None = None
    execution_error: str | None = None
    context: Context | None = None
