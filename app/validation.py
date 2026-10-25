"""Input rules shared by the auth and complaint routes."""
import re

# One minimum for register AND change-password. The Flutter register form
# uses the same number.
MIN_PASSWORD_LENGTH = 8
# bcrypt only reads the first 72 bytes (and bcrypt 5 raises on longer input).
MAX_PASSWORD_BYTES = 72

MAX_NAME_LENGTH = 100
MAX_PHONE_LENGTH = 20
MAX_EMAIL_LENGTH = 120

MAX_DESCRIPTION_LENGTH = 5000
MAX_LOCATION_TEXT_LENGTH = 200

_EMAIL_RE = re.compile(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')


def email_error(email):
    if not email:
        return 'Email is required'
    if len(email) > MAX_EMAIL_LENGTH:
        return f'Email must be at most {MAX_EMAIL_LENGTH} characters'
    if not _EMAIL_RE.match(email):
        return 'Enter a valid email address'
    return None


def password_error(password):
    if not isinstance(password, str) or len(password) < MIN_PASSWORD_LENGTH:
        return f'Password must be at least {MIN_PASSWORD_LENGTH} characters'
    if len(password.encode('utf-8')) > MAX_PASSWORD_BYTES:
        return f'Password must be at most {MAX_PASSWORD_BYTES} bytes'
    return None
