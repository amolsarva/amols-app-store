from __future__ import annotations

import argparse
import json
import time
import urllib.parse
import urllib.request
import webbrowser
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from secrets import token_urlsafe

from .paths import data_path


AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
GMAIL_SCOPE = "https://mail.google.com/"
DEFAULT_TOKEN_PATH = data_path("oauth_token.json")
PLACEHOLDER_SECRET_PATHS = {
    "/path/to/client_secret.json",
    "path/to/client_secret.json",
    "/path/to/credentials.json",
}


class OAuthError(RuntimeError):
    pass


@dataclass(frozen=True)
class OAuthConfig:
    client_id: str
    client_secret: str


def load_client_config(path: Path) -> OAuthConfig:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise OAuthError(
            f"OAuth client secrets file not found: {path}. Download the JSON from "
            "Google Cloud Console and save it in Downloads or pass its real path."
        ) from error
    except json.JSONDecodeError as error:
        raise OAuthError(f"{path} is not valid JSON.") from error
    config = raw.get("installed") or raw.get("web") or raw
    client_id = config.get("client_id")
    client_secret = config.get("client_secret")
    if not client_id or not client_secret:
        raise OAuthError(f"{path} does not contain client_id and client_secret")
    return OAuthConfig(client_id=client_id, client_secret=client_secret)


def get_access_token(args: argparse.Namespace) -> str:
    token_path = Path(args.oauth_token_file)
    token = load_token(token_path)
    if token and token.get("access_token") and not is_expired(token):
        return str(token["access_token"])
    if token and token.get("refresh_token"):
        config = config_from_token(token)
        if config is None:
            client_secrets = resolve_client_secrets_path(args.oauth_client_secrets)
            config = load_client_config(client_secrets)
        refreshed = refresh_access_token(config, str(token["refresh_token"]))
        merged = {**token, **refreshed}
        save_token(token_path, merged)
        return str(merged["access_token"])
    client_secrets = resolve_client_secrets_path(args.oauth_client_secrets)
    config = load_client_config(client_secrets)
    new_token = run_local_oauth_flow(config)
    new_token["client_id"] = config.client_id
    new_token["client_secret"] = config.client_secret
    save_token(token_path, new_token)
    return str(new_token["access_token"])


def config_from_token(token: dict[str, object]) -> OAuthConfig | None:
    client_id = token.get("client_id")
    client_secret = token.get("client_secret")
    if not isinstance(client_id, str) or not isinstance(client_secret, str):
        return None
    return OAuthConfig(client_id=client_id, client_secret=client_secret)


def resolve_client_secrets_path(raw_path: str | None) -> Path:
    if raw_path:
        expanded = Path(raw_path).expanduser()
        if raw_path in PLACEHOLDER_SECRET_PATHS:
            raise OAuthError(
                "--oauth-client-secrets must be the real JSON file path, not "
                "/path/to/client_secret.json."
            )
        return expanded
    discovered = discover_client_secrets()
    if discovered:
        print(f"Using OAuth client secrets: {discovered}")
        return discovered
    raise OAuthError(
        "No OAuth client secrets JSON found. Download it from Google Cloud Console "
        "as a Desktop app credential, save it to ~/Downloads, then rerun this "
        "command with --auth oauth2. You can also pass the exact file with "
        "--oauth-client-secrets ~/Downloads/client_secret_....json."
    )


def discover_client_secrets() -> Path | None:
    home = Path.home()
    search_roots = [home / "Downloads", home / "Desktop", home / "Documents"]
    patterns = ["client_secret*.json", "*client*secret*.json", "credentials*.json"]
    candidates: list[Path] = []
    for root in search_roots:
        if not root.exists():
            continue
        for pattern in patterns:
            candidates.extend(path for path in root.glob(pattern) if path.is_file())
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)


def load_token(path: Path) -> dict[str, object] | None:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def save_token(path: Path, token: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(token, indent=2, sort_keys=True), encoding="utf-8")
    path.chmod(0o600)


def is_expired(token: dict[str, object]) -> bool:
    expires_at = float(token.get("expires_at", 0))
    return expires_at <= time.time() + 120


def run_local_oauth_flow(config: OAuthConfig) -> dict[str, object]:
    server = OAuthCallbackServer(("127.0.0.1", 0), OAuthCallbackHandler)
    redirect_uri = f"http://127.0.0.1:{server.server_port}/"
    state = token_urlsafe(24)
    query = urllib.parse.urlencode(
        {
            "client_id": config.client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": GMAIL_SCOPE,
            "access_type": "offline",
            "prompt": "consent",
            "state": state,
        }
    )
    url = f"{AUTH_URL}?{query}"
    print(f"Opening browser for Google OAuth. If it does not open, visit:\n{url}")
    webbrowser.open(url)
    server.handle_request()
    if server.error:
        raise RuntimeError(f"OAuth failed: {server.error}")
    if not server.code:
        raise RuntimeError("OAuth failed: no authorization code received")
    if server.state != state:
        raise RuntimeError("OAuth failed: state mismatch")
    return exchange_code(config, server.code, redirect_uri)


def exchange_code(config: OAuthConfig, code: str, redirect_uri: str) -> dict[str, object]:
    payload = {
        "client_id": config.client_id,
        "client_secret": config.client_secret,
        "code": code,
        "grant_type": "authorization_code",
        "redirect_uri": redirect_uri,
    }
    return token_request(payload)


def refresh_access_token(config: OAuthConfig, refresh_token: str) -> dict[str, object]:
    payload = {
        "client_id": config.client_id,
        "client_secret": config.client_secret,
        "refresh_token": refresh_token,
        "grant_type": "refresh_token",
    }
    return token_request(payload)


def token_request(payload: dict[str, str]) -> dict[str, object]:
    encoded = urllib.parse.urlencode(payload).encode("utf-8")
    request = urllib.request.Request(
        TOKEN_URL,
        data=encoded,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        token = json.loads(response.read().decode("utf-8"))
    if "expires_in" in token:
        token["expires_at"] = time.time() + int(token["expires_in"])
    return token


class OAuthCallbackServer(HTTPServer):
    code: str | None = None
    state: str | None = None
    error: str | None = None


class OAuthCallbackHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        self.server.code = first(params.get("code"))
        self.server.state = first(params.get("state"))
        self.server.error = first(params.get("error"))
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        if self.server.error:
            self.wfile.write(b"OAuth failed. You can close this tab.")
        else:
            self.wfile.write(b"OAuth complete. You can close this tab.")

    def log_message(self, format: str, *args: object) -> None:
        return


def first(values: list[str] | None) -> str | None:
    if not values:
        return None
    return values[0]
