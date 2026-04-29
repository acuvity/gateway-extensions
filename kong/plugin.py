from enum import verify
import httpx
import json
import os
Schema = (
    {"message": {"type": "string", "default": "Blocked by policy"}},
    {"provider": {"type": "string", "default": "kong-proxy"}},
    {"timeout_ms": {"type": "number", "default": 3000}},
    {"apex_url": {"type": "string", "required": False}},
    {"acuvity_token": {"type": "string", "required": False}},
)
version = "0.2.0"
priority = 1000


class Plugin:
    def __init__(self, config):
        self.config = config
        self.token = self.config.get("acuvity_token")
        self.apex_url = self.config.get("apex_url")

    def access(self, kong):
        # auth = kong.request.get_header("authorization") or ""
        # if not auth.startswith("Bearer "):
        #     return kong.response.exit(401, {"error": "missing Bearer token"})

        # token = auth.removeprefix("Bearer ").strip()

        # try:
        #     unverified = jwt.decode(token, options={"verify_signature": False})
        # except Exception as e:
        #     return kong.response.exit(401, {"error": f"invalid token: {e}"})

        # apex_url = (unverified.get("opaque") or {}).get("apex-url")
        # if not apex_url:
        #     return kong.response.exit(500, {"error": "apex-url missing from token"})

        # identity = unverified.get("identity") or []
        # provider = self.config.get("provider", "kong-proxy")
        # for i in identity:
        #     if isinstance(i, str) and i.startswith("@apptoken:name="):
        #         provider = i.split("=", 1)[1]

        # body = kong.request.get_raw_body() or "{}"
        # police_payload = {
        #     "messages": [body],
        #     "anonymization": "VariableSize",
        #     "provider": provider,
        #     "type": "Input",
        #     "tools": {"anthropic/messages": {"name": "anthropic/messages", "category": "Server"}},
        #     "user": {"claims": identity, "name": None},
        # }

        raw, err = kong.request.get_raw_body()
        if not raw:
            raw = b"{}"
        body = raw.decode("utf-8") if isinstance(raw, bytes) else str(raw)
        try:
            parsed = json.loads(body)
            messages = [m.get("content", "") for m in parsed.get("messages", []) if isinstance(m.get("content"), str)]
        except Exception:
            messages = [body]
        provider = self.config.get("provider", "kong-proxy")
        police_payload = {
            "messages": messages if messages else [body],
            "anonymization": "VariableSize",
            "provider": provider,
            "type": "Input",
            "tools": {"anthropic/messages": {"name": "anthropic/messages", "category": "Server"}},
            "user": {"userClaims": [
                f"provider={provider}",
                "@apptoken:name=kong-demo"
            ], "username": "kanav@acuvity.ai"},
        }

        police_url = f"{self.apex_url}/_acuvity/police"
        try:
            with httpx.Client(timeout=(self.config.get("timeout_ms", 3000) / 1000.0), verify=False) as client:
                res = client.post(
                    police_url,
                    json=police_payload,
                    headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
                )
        except Exception as e:
            return kong.response.exit(403, {"error": f"policy check failed: {e}"})

        if res.status_code != 200:
            return kong.response.exit(403, {"error": f"policy check HTTP {res.status_code}: {res.text}"})

        try:
            result = res.json()
        except Exception:
            return kong.response.exit(403, {"error": self.config.get("message", "Blocked by policy")})

        if result.get("decision") == "Deny":
            reason = (result.get("reasons") or [self.config.get("message", "Blocked by policy")])[0]
            return kong.response.exit(403, {"error": reason})

        # Allow request to upstream
        extractions = result.get("extractions", [])
        if extractions:
            ext = extractions[0]
            has_redaction = any(d.get("redacted") for d in ext.get("detections", []))
            if has_redaction:
                redacted_text = ext.get("data", "")
                original = json.loads(body)
                # Replace user message content with redacted version
                for msg in original.get("messages", []):
                    if msg.get("role") == "user" and isinstance(msg.get("content"), str):
                        msg["content"] = redacted_text
                kong.service.request.set_raw_body(json.dumps(original))
        
        kong.service.request.clear_header("Accept-Encoding")
        return

    def response(self, kong):
    
        raw, err = kong.service.response.get_raw_body()
        if not raw:
            return
        body = raw.decode("utf-8") if isinstance(raw, bytes) else str(raw)
    
        # Detect which service based on the original request path
        path = kong.request.get_path() or ""
    
        try:
            parsed = json.loads(body)
        except Exception:
            parsed = {}
    
        if "/anthropic" in path:
            # Anthropic response: {"content": [{"type": "text", "text": "..."}], ...}
            content_blocks = parsed.get("content", [])
            messages = [b["text"] for b in content_blocks if b.get("type") == "text" and "text" in b]
            tool_name = "anthropic/messages"
        elif "/exa" in path:
            # Exa response: {"results": [{"title": "...", "url": "...", ...}]}
            results = parsed.get("results", [])
            messages = [f"{r.get('title', '')} {r.get('url', '')} {r.get('text', '')}" for r in results]
            tool_name = "exa/search"
        else:
            messages = [body]
            tool_name = "unknown"
    
        if not messages:
            return
    
        provider = self.config.get("provider", "scan/kong-proxy")
        police_payload = {
            "messages": messages,
            "anonymization": "VariableSize",
            "provider": provider,
            "type": "Output",
            "tools": {tool_name: {"name": tool_name, "category": "Server"}},
            "user": {"userClaims": [
                f"provider={provider}",
                "@apptoken:name=kong-demo"
            ], "username": "kanav@acuvity.ai"},
        }

        police_url = f"{self.apex_url}/_acuvity/police"
        try:
            with httpx.Client(timeout=(self.config.get("timeout_ms", 3000) / 1000.0), verify=False) as client:
                res = client.post(
                    police_url,
                    json=police_payload,
                    headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
                )
        except Exception as e:
            return kong.response.exit(403, {"error": f"output policy check failed: {e}"})

        if res.status_code != 200:
            return kong.response.exit(403, {"error": f"output policy check HTTP {res.status_code}: {res.text}"})

        try:
            result = res.json()
        except Exception:
            return

        if result.get("decision") == "Deny":
            reason = (result.get("reasons") or [self.config.get("message", "Blocked by policy")])[0]
            return kong.response.exit(403, {"error": reason})
        return

if __name__ == "__main__":
    from kong_pdk.cli import start_dedicated_server

    start_dedicated_server("py-blocker", Plugin, version, priority, Schema)