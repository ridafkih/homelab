import os

_provider = os.environ["SEAFILE_OAUTH_PROVIDER_URL"]

ENABLE_OAUTH = True
OAUTH_CREATE_UNKNOWN_USER = False
OAUTH_ACTIVATE_USER_AFTER_CREATION = False
OAUTH_ENABLE_INSECURE_TRANSPORT = False
OAUTH_PROVIDER = "pocket-id"
OAUTH_CLIENT_ID = "seafile"
OAUTH_CLIENT_SECRET = os.environ["SEAFILE_OAUTH_CLIENT_SECRET"]
OAUTH_REDIRECT_URL = "https://%s/oauth/callback/" % os.environ["SEAFILE_SERVER_HOSTNAME"]
OAUTH_AUTHORIZATION_URL = _provider + "/authorize"
OAUTH_TOKEN_URL = _provider + "/api/oidc/token"
OAUTH_USER_INFO_URL = _provider + "/api/oidc/userinfo"
OAUTH_SCOPE = ["openid", "profile", "email"]
OAUTH_ATTRIBUTE_MAP = {
    "sub": (True, "uid"),
    "email": (False, "contact_email"),
    "name": (False, "name"),
}
