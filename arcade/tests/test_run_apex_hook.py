import pytest
from fastapi import HTTPException
from hooks.server import run_apex_hook
from hooks.models import Context, HookResponse, ToolInfo


TOOL = ToolInfo(name="my-tool", toolkit="my-toolkit")
CONTEXT = Context(user_id="alice")


@pytest.fixture
def mock_req(mocker):
    return mocker.Mock(headers={})


@pytest.fixture
def mock_verify(mocker):
    return mocker.patch("hooks.server.verify_apex_auth")

@pytest.fixture
def mock_call_apex(mocker):
    return mocker.patch("hooks.server.call_apex", new_callable=mocker.AsyncMock)

@pytest.mark.anyio
async def test_missing_police_url(mock_req, mock_verify):
    mock_verify.return_value = ("mytoken", None, "my-app", ["user=alice"])
    
    with pytest.raises(HTTPException) as exc:
        await run_apex_hook(mock_req, CONTEXT, TOOL, {"input": "hello"}, "Input", "inputs")
    
    assert exc.value.status_code == 500
    assert "apex-url missing" in exc.value.detail

@pytest.mark.anyio
async def test_no_context_sends_empty_claims(mock_req, mock_verify, mock_call_apex):
    mock_verify.return_value = ("tk", "url", "app", ["claims"])
    mock_call_apex.return_value = {"decision": "Allow"}

    await run_apex_hook(mock_req, None, TOOL, {"input": "hello"}, "Input", "inputs")
    
    args, _ = mock_call_apex.call_args
    # messages, msg_type, tools, claims, user_id are positional
    assert args[3] == []   # claims
    assert args[4] is None  # user_id

@pytest.mark.anyio
async def test_deny_returns_check_failed(mock_req, mock_verify, mock_call_apex):
    mock_verify.return_value = ("tk", "url", "app", ["claims"])
    mock_call_apex.return_value = {"decision": "Deny", "reasons": ["policy violation"]}
    
    result = await run_apex_hook(mock_req, CONTEXT, TOOL, {"input": "hello"}, "Input", "inputs")
    
    assert result.code == "CHECK_FAILED"
    assert result.error_message == "policy violation"