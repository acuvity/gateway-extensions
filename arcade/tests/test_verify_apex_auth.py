import jwt
import pytest
from fastapi import HTTPException
from hooks.server import verify_apex_auth
from cryptography.hazmat.primitives.asymmetric import rsa

@pytest.fixture
def mock_req(mocker):
    # We return a Mock object that we can configure per test
    return mocker.Mock(headers={})

def test_missing_auth_header(mock_req):
    # Arrange: Headers are already empty by default or set here
    mock_req.headers = {} 
    
    with pytest.raises(HTTPException) as exc:
        verify_apex_auth(mock_req)
        
    assert exc.value.status_code == 401
    assert "missing Bearer token" in exc.value.detail

def test_non_bearer_token(mock_req):
    # Arrange: Inject the specific case
    mock_req.headers = {"Authorization": "Basic abc"}
    
    with pytest.raises(HTTPException) as exc:
        verify_apex_auth(mock_req)
        
    assert exc.value.status_code == 401
    assert "missing Bearer token" in exc.value.detail

def test_invalid_issuer(mock_req):
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    token = jwt.encode(
        {"iss": "https://api.test.ai", "identity": ["user=alice"]},
        private_key,
        algorithm="RS256",
        headers={"kid": "test-key"},
    )
    mock_req.headers = {"Authorization": f"Bearer {token}"}
    with pytest.raises(HTTPException) as exc:
        verify_apex_auth(mock_req)
    assert exc.value.status_code == 401
    assert "unsupported issuer" in exc.value.detail

def test_return_token_and_provider(mock_req, mocker):
    
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    token = jwt.encode(
        {"iss": "https://api.acuvity.dev", "identity": ["user=alice"]},
        private_key,
        algorithm="RS256",
        headers={"kid": "test-key"},
    )

    signing_key = mocker.Mock()
    signing_key.key_id = "test-key"
    signing_key.key = private_key.public_key()

    jwks = mocker.Mock()
    jwks.keys = [signing_key]

    mocker.patch("hooks.server.ssl.create_default_context")
    mocker.patch("hooks.server.httpx.get", return_value=mocker.Mock(json=lambda: {}))
    mocker.patch("hooks.server.jwt.PyJWKSet.from_dict", return_value=jwks)

    mock_req.headers = {"Authorization": f"Bearer {token}"}
    result_token, _, provider, _ = verify_apex_auth(mock_req)
    assert result_token == token
    assert provider == "arcade-dev"


def test_no_matching_kid(mock_req, mocker):
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    token = jwt.encode(
        {"iss": "https://api.acuvity.dev", "identity": ["user=alice"]},
        private_key,
        algorithm="RS256",
        headers={"kid": "test-key"},
    )

    signing_key = mocker.Mock()
    signing_key.key_id = "other-key"  # deliberately mismatched

    jwks = mocker.Mock()
    jwks.keys = [signing_key]

    mocker.patch("hooks.server.ssl.create_default_context")
    mocker.patch("hooks.server.httpx.get", return_value=mocker.Mock(json=lambda: {}))
    mocker.patch("hooks.server.jwt.PyJWKSet.from_dict", return_value=jwks)

    mock_req.headers = {"Authorization": f"Bearer {token}"}
    with pytest.raises(HTTPException) as exc:
        verify_apex_auth(mock_req)
    assert exc.value.status_code == 401
    assert "token signature validation failed" in exc.value.detail


def test_jwt_decode_fails(mock_req, mocker):
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    wrong_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    token = jwt.encode(
        {"iss": "https://api.acuvity.dev", "identity": ["user=alice"]},
        private_key,
        algorithm="RS256",
        headers={"kid": "test-key"},
    )

    signing_key = mocker.Mock()
    signing_key.key_id = "test-key"
    signing_key.key = wrong_key.public_key() 

    jwks = mocker.Mock()
    jwks.keys = [signing_key]

    mocker.patch("hooks.server.ssl.create_default_context")
    mocker.patch("hooks.server.httpx.get", return_value=mocker.Mock(json=lambda: {}))
    mocker.patch("hooks.server.jwt.PyJWKSet.from_dict", return_value=jwks)

    mock_req.headers = {"Authorization": f"Bearer {token}"}
    with pytest.raises(HTTPException) as exc:
        verify_apex_auth(mock_req)
    assert exc.value.status_code == 401
    assert "token signature validation failed" in exc.value.detail


def test_missing_identity(mock_req):
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    token = jwt.encode(
        {"iss": "https://api.acuvity.dev"}, 
        private_key,
        algorithm="RS256",
        headers={"kid": "test-key"},
    )
    mock_req.headers = {"Authorization": f"Bearer {token}"}
    with pytest.raises(HTTPException) as exc:
        verify_apex_auth(mock_req)
    assert exc.value.status_code == 401
    assert "identity" in exc.value.detail


def test_provider_from_apptoken(mock_req, mocker):
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    token = jwt.encode(
        {"iss": "https://api.acuvity.dev", "identity": ["@apptoken:name=my-app", "user=alice"]},
        private_key,
        algorithm="RS256",
        headers={"kid": "test-key"},
    )

    signing_key = mocker.Mock()
    signing_key.key_id = "test-key"
    signing_key.key = private_key.public_key()

    jwks = mocker.Mock()
    jwks.keys = [signing_key]

    mocker.patch("hooks.server.ssl.create_default_context")
    mocker.patch("hooks.server.httpx.get", return_value=mocker.Mock(json=lambda: {}))
    mocker.patch("hooks.server.jwt.PyJWKSet.from_dict", return_value=jwks)

    mock_req.headers = {"Authorization": f"Bearer {token}"}
    _, _, provider, _ = verify_apex_auth(mock_req)
    assert provider == "my-app"


def test_police_url_construction(mock_req, mocker):
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    token = jwt.encode(
        {
            "iss": "https://api.acuvity.dev",
            "identity": ["user=alice"],
            "opaque": {"apex-url": "https://apex.example.com"},
        },
        private_key,
        algorithm="RS256",
        headers={"kid": "test-key"},
    )

    signing_key = mocker.Mock()
    signing_key.key_id = "test-key"
    signing_key.key = private_key.public_key()

    jwks = mocker.Mock()
    jwks.keys = [signing_key]

    mocker.patch("hooks.server.ssl.create_default_context")
    mocker.patch("hooks.server.httpx.get", return_value=mocker.Mock(json=lambda: {}))
    mocker.patch("hooks.server.jwt.PyJWKSet.from_dict", return_value=jwks)

    mock_req.headers = {"Authorization": f"Bearer {token}"}
    _, police_url, _, _ = verify_apex_auth(mock_req)
    assert police_url == "https://apex.example.com/_acuvity/police"


def test_missing_apex_url(mock_req, mocker):
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    token = jwt.encode(
        {"iss": "https://api.acuvity.dev", "identity": ["user=alice"]},  # no opaque
        private_key,
        algorithm="RS256",
        headers={"kid": "test-key"},
    )

    signing_key = mocker.Mock()
    signing_key.key_id = "test-key"
    signing_key.key = private_key.public_key()

    jwks = mocker.Mock()
    jwks.keys = [signing_key]

    mocker.patch("hooks.server.ssl.create_default_context")
    mocker.patch("hooks.server.httpx.get", return_value=mocker.Mock(json=lambda: {}))
    mocker.patch("hooks.server.jwt.PyJWKSet.from_dict", return_value=jwks)

    mock_req.headers = {"Authorization": f"Bearer {token}"}
    _, police_url, _, _ = verify_apex_auth(mock_req)
    assert police_url is None


def test_jwks_fetch_failure(mock_req, mocker):
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    token = jwt.encode(
        {"iss": "https://api.acuvity.dev", "identity": ["user=alice"]},
        private_key,
        algorithm="RS256",
        headers={"kid": "test-key"},
    )

    mocker.patch("hooks.server.ssl.create_default_context")
    mocker.patch("hooks.server.httpx.get", side_effect=Exception("network error"))

    mock_req.headers = {"Authorization": f"Bearer {token}"}
    with pytest.raises(HTTPException) as exc:
        verify_apex_auth(mock_req)
    assert exc.value.status_code == 401
    assert "token signature validation failed" in exc.value.detail
