import json

import pytest
import respx
from httpx import RequestError, Response

from hooks.server import call_apex

ARGS = dict(
    messages=["hello"],
    msg_type="Input",
    tools={"my-toolkit/my-tool": {"name": "my-toolkit/my-tool", "category": "Server"}},
    claims=["user=alice"],
    user_id="alice",
    token="mytoken",
    police_url="https://apex.example.com/_acuvity/police",
    provider="my-app",
)


@pytest.mark.anyio
@respx.mock
async def test_success():
    respx.post("https://apex.example.com/_acuvity/police").mock(
        return_value=Response(200, json={"decision": "Allow"})
    )

    result = await call_apex(**ARGS)
    assert result == {"decision": "Allow"}


@pytest.mark.anyio
@respx.mock
async def test_non_200_returns_deny():
    respx.post("https://apex.example.com/_acuvity/police").mock(
        return_value=Response(403, text="Forbidden")
    )

    result = await call_apex(**ARGS)
    assert result["decision"] == "Deny"
    assert "403" in result["reasons"][0]


@pytest.mark.anyio
@respx.mock
async def test_network_error_returns_deny():
    respx.post("https://apex.example.com/_acuvity/police").mock(
        side_effect=RequestError("connection refused")
    )

    result = await call_apex(**ARGS)
    assert result["decision"] == "Deny"
    assert "Failed to reach apex" in result["reasons"][0]


@pytest.mark.anyio
@respx.mock
async def test_request_body():
    route = respx.post("https://apex.example.com/_acuvity/police").mock(
        return_value=Response(200, json={"decision": "Allow"})
    )

    await call_apex(**ARGS)

    body = json.loads(route.calls.last.request.content)
    assert body["messages"] == ["hello"]
    assert body["type"] == "Input"
    assert body["provider"] == "my-app"
    assert body["user"] == {"claims": ["user=alice"], "name": "alice"}
    assert route.calls.last.request.headers["Authorization"] == "Bearer mytoken"
