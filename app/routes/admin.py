"""Minimal admin portal: server-rendered pages behind the shared ADMIN_API_KEY.

Meant for localhost / a trusted network only (see README). One shared key,
no per-admin identity. The blueprint is always registered but every request
answers 503 until ADMIN_API_KEY is set.

The status change and the blockchain retry reuse the same code the admin API
uses (complaints.apply_status_change, chain_sync.retry_log).
"""
import os
import secrets
import time
from datetime import timedelta

from flask import (Blueprint, abort, current_app, flash, g, redirect,
                   render_template, request, session, url_for)
from flask_limiter.util import get_remote_address
from sqlalchemy import func

from app import chain_sync, db
from app.limiter import ADMIN_LOGIN_LIMIT, limiter
from app.models import Complaint, User
from app.routes.complaints import _evidence_list, apply_status_change
from app.statuses import STATUS_FLOW

admin_bp = Blueprint('admin', __name__, url_prefix='/admin')

SESSION_MINUTES = 30
PAGE_SIZE = 25
CHAIN_STATES = ('pending', 'confirmed', 'failed')
ETHERSCAN_TX = 'https://sepolia.etherscan.io/tx/'

# A request that came through a tunnel or reverse proxy (Cloudflare, ngrok,
# nginx...) carries at least one of these. The portal is local-only, so such
# requests get the same 404 as a page that does not exist.
PROXY_HEADERS = (
    'Cf-Connecting-Ip', 'Cf-Ray', 'Cf-Visitor', 'Cf-Ipcountry', 'True-Client-Ip',
    'X-Forwarded-For', 'X-Forwarded-Host', 'X-Forwarded-Proto', 'X-Forwarded-Server',
    'Forwarded', 'X-Real-Ip', 'Via',
)
LOCAL_HOSTS = ('127.0.0.1', 'localhost', '[::1]')


# ------------------------------------------------------------------ guards

def _is_local_request():
    """Opened directly on this machine: no proxy headers and a loopback Host."""
    if any(h in request.headers for h in PROXY_HEADERS):
        return False
    host = request.host.lower()
    host = host[:host.index(']') + 1] if host.startswith('[') else host.split(':')[0]
    return host in LOCAL_HOSTS


def _key_configured():
    return bool(os.getenv('ADMIN_API_KEY', ''))


def _logged_in():
    stamp = session.get('admin_at')
    if not isinstance(stamp, (int, float)):
        return False
    return 0 <= time.time() - stamp < SESSION_MINUTES * 60


def _csrf_token():
    token = session.get('csrf')
    if not token:
        token = secrets.token_urlsafe(32)
        session['csrf'] = token
    return token


def _csrf_ok():
    sent = request.form.get('csrf_token', '')
    expected = session.get('csrf', '')
    return bool(expected) and secrets.compare_digest(sent.encode('utf-8'), expected.encode('utf-8'))


@admin_bp.before_request
def _before():
    g.csp_nonce = secrets.token_urlsafe(16)
    if not _is_local_request():
        abort(404)  # looks exactly like a page that does not exist
    if not _key_configured():
        return render_template('admin/message.html', title='Admin portal disabled',
                               message='The admin portal is disabled because ADMIN_API_KEY is not set on the server.'), 503
    if not current_app.config.get('SECRET_KEY'):
        return render_template('admin/message.html', title='Admin portal disabled',
                               message='The admin portal is disabled because SECRET_KEY is not set on the server.'), 503
    if request.method == 'POST' and not _csrf_ok():
        abort(400, 'Missing or invalid CSRF token. Reload the page and try again.')
    if request.endpoint not in ('admin.login', 'admin.login_page') and not _logged_in():
        session.pop('admin_at', None)
        return redirect(url_for('admin.login_page'))


@admin_bp.after_request
def _headers(response):
    nonce = getattr(g, 'csp_nonce', '')
    response.headers['Content-Security-Policy'] = (
        "default-src 'none'; "
        f"style-src 'nonce-{nonce}'; "
        "img-src 'self' data:; "
        "form-action 'self'; "
        "base-uri 'none'; "
        "frame-ancestors 'none'"
    )
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Pragma'] = 'no-cache'
    return response


@admin_bp.errorhandler(400)
def _bad_request(error):
    return render_template('admin/message.html', title='Request rejected',
                           message=getattr(error, 'description', 'Bad request.')), 400


@admin_bp.app_context_processor
def _inject():
    return {'csrf_token': _csrf_token, 'nonce': getattr(g, 'csp_nonce', ''),
            'etherscan_tx': ETHERSCAN_TX,
            'admin_logged_in': _key_configured() and _logged_in()}


# ------------------------------------------------------------------- login

@admin_bp.get('/login')
def login_page():
    if _key_configured() and _logged_in():
        return redirect(url_for('admin.dashboard'))
    return render_template('admin/login.html')


@admin_bp.post('/login')
@limiter.limit(ADMIN_LOGIN_LIMIT, key_func=get_remote_address)
def login():
    given = request.form.get('key', '')
    expected = os.getenv('ADMIN_API_KEY', '')
    if secrets.compare_digest(given.encode('utf-8'), expected.encode('utf-8')):
        session.clear()
        session.permanent = True
        session['admin_at'] = time.time()
        _csrf_token()  # fresh token for the new session
        return redirect(url_for('admin.dashboard'))
    flash('That key is not correct.', 'error')
    return render_template('admin/login.html'), 401


@admin_bp.post('/logout')
def logout():
    session.clear()
    return redirect(url_for('admin.login_page'))


# ------------------------------------------------------------------- pages

def _chain_state(complaint):
    return complaint.chain_status or 'pending'


@admin_bp.get('/')
def dashboard():
    by_status = dict(db.session.query(Complaint.status, func.count()).group_by(Complaint.status).all())
    by_chain = {}
    for state, count in db.session.query(Complaint.chain_status, func.count()).group_by(Complaint.chain_status).all():
        by_chain[state or 'pending'] = by_chain.get(state or 'pending', 0) + count
    latest = Complaint.query.order_by(Complaint.created_at.desc(), Complaint.id.desc()).limit(50).all()
    return render_template(
        'admin/dashboard.html',
        status_counts=[(s, by_status.get(s, 0)) for s in STATUS_FLOW],
        chain_counts=[(c, by_chain.get(c, 0)) for c in CHAIN_STATES],
        total=sum(by_status.values()),
        reports=latest,
        chain_state=_chain_state,
    )


@admin_bp.get('/reports')
def reports():
    status = request.args.get('status', '').strip().upper()
    if status and status not in STATUS_FLOW:
        status = ''
    try:
        page = max(1, int(request.args.get('page', '1')))
    except ValueError:
        page = 1

    query = Complaint.query
    if status:
        query = query.filter(Complaint.status == status)
    total = query.count()
    items = (query.order_by(Complaint.created_at.desc(), Complaint.id.desc())
             .offset((page - 1) * PAGE_SIZE).limit(PAGE_SIZE).all())
    pages = max(1, -(-total // PAGE_SIZE))
    return render_template('admin/reports.html', reports=items, status=status, page=page,
                           pages=pages, total=total, statuses=STATUS_FLOW, chain_state=_chain_state)


def _get_or_404(complaint_id):
    complaint = Complaint.query.filter_by(complaint_id=complaint_id).first()
    if not complaint:
        abort(404)
    return complaint


def _next_status(complaint):
    if complaint.status not in STATUS_FLOW:
        return None
    index = STATUS_FLOW.index(complaint.status)
    return STATUS_FLOW[index + 1] if index + 1 < len(STATUS_FLOW) else None


@admin_bp.get('/report/<complaint_id>')
def report_detail(complaint_id):
    complaint = _get_or_404(complaint_id)
    reporter = None
    if not complaint.anonymous:
        user = db.session.get(User, complaint.user_id)
        reporter = user.name if user else None  # name only, never email or id
    current = STATUS_FLOW.index(complaint.status) if complaint.status in STATUS_FLOW else -1
    return render_template(
        'admin/report.html',
        c=complaint,
        reporter=reporter,
        evidence=_evidence_list(complaint.ipfs_cid or ''),
        chain=_chain_state(complaint),
        flow=[(s, i < current, i == current) for i, s in enumerate(STATUS_FLOW)],
        next_status=_next_status(complaint),
    )


@admin_bp.post('/report/<complaint_id>/status')
def change_status(complaint_id):
    complaint = _get_or_404(complaint_id)
    wanted = request.form.get('status', '').strip().upper()
    expected = _next_status(complaint)
    if expected is None or wanted != expected:
        flash(f'Status can only move forward one step at a time '
              f'(next step: {expected or "none, already resolved"}).', 'error')
        return redirect(url_for('admin.report_detail', complaint_id=complaint_id))

    previous = apply_status_change(complaint, wanted)
    if complaint.status_tx:
        message = (f'Status changed {previous} to {complaint.status}. Blockchain update sent '
                   f'(tx {complaint.status_tx[:12]}...), waiting for confirmation.')
    elif complaint.chain_error:
        message = (f'Status changed {previous} to {complaint.status}. The blockchain update '
                   f'failed for now and will be retried automatically: {complaint.chain_error}')
    else:
        message = (f'Status changed {previous} to {complaint.status}. The blockchain update is '
                   f'pending and will be sent automatically.')
    flash(message, 'ok')
    return redirect(url_for('admin.report_detail', complaint_id=complaint_id))


@admin_bp.post('/report/<complaint_id>/retry')
def retry_chain(complaint_id):
    complaint = _get_or_404(complaint_id)
    if _chain_state(complaint) != 'failed':
        flash('Only reports whose blockchain log failed can be retried.', 'error')
    else:
        chain_sync.retry_log(complaint)
        if complaint.blockchain_tx:
            flash(f'Blockchain log re-sent (tx {complaint.blockchain_tx[:12]}...), waiting for confirmation.', 'ok')
        else:
            flash('Retry attempted but no transaction was sent yet; it will be retried automatically.', 'error')
    return redirect(url_for('admin.report_detail', complaint_id=complaint_id))
