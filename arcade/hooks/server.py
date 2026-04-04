import logging
import os
import ssl

from fastapi import FastAPI, HTTPException, Request
import httpx
import json
from dotenv import load_dotenv
from typing import Any
from hooks.models import (
    Context,
    HookResponse,
    PostRequest,
    PreRequest,
    ToolInfo,
    AccessRequest,
)
import jwt
import urllib.request
import json as _json

load_dotenv()

logging.basicConfig(level=logging.INFO, force=True)
log = logging.getLogger(__name__)

app = FastAPI(title="Arcade Hooks Server")

SUPPORTED_ISSUERS = {
    "https://api.acuvity.ai",
    "https://api.acuvity.dev",
    "https://api.acuvity.us",
}


def build_claims(
    user_id: str, context: Context | None = None, provider: str | None = None
) -> list[str]:
    claims = [
        f"provider={provider}" if provider else "provider=arcade-hooks",
        f"arcade:user-id={user_id}",
    ]

    oauth_user_info = None
    if context and context.authorization:
        for auth in (
            context.authorization
            if isinstance(context.authorization, list)
            else [context.authorization]
        ):
            oauth_user_info = auth.get("oauth2", {}).get("user_info")
            if oauth_user_info:
                break

    if oauth_user_info:
        email = oauth_user_info.get("email", "")
        domain = email.split("@")[1] if "@" in email else ""
        claims += [
            f"arcade:oauth2:email={email}",
            f"arcade:user-email={email}",
            f"arcade:user-domain={domain}",
        ]
    else:
        domain = user_id.split("@")[1] if "@" in user_id else ""
        claims += [
            f"arcade:user-email={user_id}",
            f"arcade:user-domain={domain}",
        ]

    return claims


def verify_apex_auth(request: Request) -> tuple[str, str | None]:
    auth_token = request.headers.get("Authorization", "")
    token = auth_token.removeprefix("Bearer ") if auth_token.startswith("Bearer ") else None
    if not token:
        raise HTTPException(status_code=401, detail="missing Bearer token")

    # decode without validation to extract iss
    try:
        unverified = jwt.decode(token, options={"verify_signature": False})
        if "iss" not in unverified:
            raise ValueError("token has no 'iss' field")
    except Exception as e:
        raise HTTPException(status_code=401, detail=f"invalid token: {e}") from e

    iss = unverified["iss"]
    log.info("token issuer: %s", iss)

    if iss not in SUPPORTED_ISSUERS:
        raise HTTPException(status_code=401, detail=f"unsupported issuer: {iss}")

    # fetch JWKS from issuer and validate signature + audience
    jwks_url = f"{iss}/.well-known/jwks.json"
    log.info("fetching JWKS from: %s", jwks_url)
    try:
        ssl_ctx = ssl.create_default_context()
        if os.getenv("CA_PATH"):
            ssl_ctx.load_verify_locations(os.path.expanduser(os.getenv("CA_PATH", "")))
        else:
            ssl_ctx.load_verify_locations("/var/task/certificates/ca.pem")

        with urllib.request.urlopen(jwks_url, context=ssl_ctx) as r:
            jwks_data = _json.loads(r.read().decode())

        jwks = jwt.PyJWKSet.from_dict(jwks_data)
        header = jwt.get_unverified_header(token)
        kid = header.get("kid")
        signing_key = next((k for k in jwks.keys if k.key_id == kid), None)
        if signing_key is None:
            raise ValueError(f"no matching key found for kid={kid}")
        audience = unverified.get("aud")
        jwt.decode(token, signing_key.key, algorithms=["RS256", "ES256"], audience=audience)
        log.info("token validated successfully for issuer: %s", iss)
    except Exception as e:
        log.error("token validation failed: %s", e)
        raise HTTPException(
            status_code=401, detail=f"token signature validation failed: {e}"
        ) from e

    # extract apex-url from validated token
    apex_url = unverified.get("opaque", {}).get("apex-url")
    provider = unverified.get("opaque", {}).get("usr/apex/provider")
    police_url = (apex_url + "/_acuvity/police") if apex_url else None
    log.info("police_url: %s", police_url)
    log.info("provider: %s", provider)
    return token, police_url, provider


async def call_apex(
    messages: list[str],
    msg_type: str,
    tools: dict,
    claims: list[str],
    user_id: str | None,
    token: str,
    police_url: str,
    provider: str | None,
) -> dict:
    log.info(
        "calling apex police_url=%s msg_type=%s user_id=%s tools=%s",
        police_url,
        msg_type,
        user_id,
        list(tools.keys()),
    )
    ssl_ctx = ssl.create_default_context()
    if os.getenv("CA_PATH"):
        ssl_ctx.load_verify_locations(os.path.expanduser(os.getenv("CA_PATH", "")))
    else:
        ssl_ctx.load_verify_locations("/var/task/certificates/ca.pem")
    try:
        async with httpx.AsyncClient(verify=ssl_ctx) as client:
            res = await client.post(
                police_url,
                json={
                    "messages": messages,
                    "anonymization": "VariableSize",
                    "provider": provider,
                    "type": msg_type,
                    "tools": tools,
                    "user": {"claims": claims, "name": user_id},
                },
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
            )
        if res.status_code != 200:
            log.error("apex call failed: %s, response code %s", res.text, res.status_code)
            return {
                "decision": "Deny",
                "reasons": [f"Apex call failed with status code {res.status_code}"],
            }
        log.info("apex status=%s", res.status_code)
        return res.json()
    except httpx.RequestError as e:
        log.error("apex network error: %s", e)
        return {"decision": "Deny", "reasons": [f"Failed to reach apex: {e}"]}


def handle_apex_response(res_json: dict, override_key: str) -> HookResponse:
    log.info("apex response: %s", res_json)
    if res_json.get("decision") == "Deny":
        return HookResponse(
            code="CHECK_FAILED",
            error_message=res_json.get("reasons", ["Unknown reason"])[0],
        )
    if res_json.get("decision") == "Allow":
        data = json.loads(res_json.get("extractions", [{}])[0].get("data", "{}"))
        for detection in res_json.get("extractions", [{}])[0].get("detections", []):
            if detection.get("redacted"):
                return HookResponse(code="OK", override={override_key: data})
    return HookResponse()


async def run_apex_hook(
    request: Request,
    context: Context | None,
    tool: ToolInfo,
    message: Any,
    msg_type: str,
    override_key: str,
) -> HookResponse:
    log.info(
        "run_apex_hook msg_type=%s tool=%s/%s user_id=%s",
        msg_type,
        tool.toolkit,
        tool.name,
        context.user_id if context else None,
    )
    token, police_url, provider = verify_apex_auth(request)  # raises HTTPException(401) on failure
    if not police_url:
        raise HTTPException(status_code=500, detail="apex-url missing from token")

    user_id = context.user_id if context else None
    claims = build_claims(user_id, context, provider) if user_id else []
    tool_input = f"{tool.toolkit}/{tool.name}"
    tools = {tool_input: {"name": tool_input, "category": "Server"}}
    res_json = await call_apex(
        [json.dumps(message)],
        msg_type,
        tools,
        claims,
        user_id,
        token=token,
        police_url=police_url,
        provider=provider,
    )
    return handle_apex_response(res_json, override_key)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/access")
async def access_hook(request: Request, payload: AccessRequest):
    log.info(
        "access_hook user_id=%s toolkits=%s",
        payload.user_id,
        list(payload.toolkits.keys()),
    )
    verify_apex_auth(request)  # raises HTTPException(401) on failure
    return {}


@app.post("/pre")
async def pre_hook(request: Request, payload: PreRequest) -> HookResponse:
    return await run_apex_hook(
        request, payload.context, payload.tool, payload.inputs, "Input", "inputs"
    )


@app.post("/post")
async def post_hook(request: Request, payload: PostRequest) -> HookResponse:
    return await run_apex_hook(
        request, payload.context, payload.tool, payload.output, "Output", "outputs"
    )
