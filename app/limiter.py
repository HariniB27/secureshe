"""Rate limiting. In-memory by default (fine for one dev process); set
RATELIMIT_STORAGE_URI (e.g. a Redis URL) when running more than one worker.
Each limit can be overridden with an environment variable."""
import os

from flask_limiter import Limiter
from flask_limiter.util import get_remote_address

limiter = Limiter(
    key_func=get_remote_address,
    storage_uri=os.getenv('RATELIMIT_STORAGE_URI', 'memory://'),
    default_limits=[],
)

LOGIN_LIMIT = os.getenv('LOGIN_RATE_LIMIT', '10 per minute')
REGISTER_LIMIT = os.getenv('REGISTER_RATE_LIMIT', '5 per minute')
PASSWORD_LIMIT = os.getenv('PASSWORD_RATE_LIMIT', '5 per minute')
RETRY_CHAIN_LIMIT = os.getenv('RETRY_CHAIN_RATE_LIMIT', '6 per minute')
ADMIN_LIMIT = os.getenv('ADMIN_RATE_LIMIT', '30 per minute')
