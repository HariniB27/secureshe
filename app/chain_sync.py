"""Keeps the database and the blockchain in step without ever blocking a request.

Lifecycle of a report's log transaction (Complaint.chain_status):

    pending   -> the tx was sent (or is waiting to be sent / retried)
    confirmed -> mined successfully
    failed    -> gave up (retries used up, or a deterministic error such as
                 the gas cap). The owner can retry from the app.

Requests send the transaction themselves and return straight away with its
hash. A single background thread then confirms receipts, retries sends that
failed or never got mined, and pushes admin status changes on-chain.
Run ONE process: the thread isn't coordinated across several workers.
"""
import logging
import os
import re
import threading
import time
from datetime import datetime, timedelta

from sqlalchemy import or_

from app import blockchain as chain
from app import db
from app.models import Complaint

log = logging.getLogger('secureshe.chain')

MAX_ATTEMPTS = int(os.getenv('CHAIN_MAX_ATTEMPTS', '3'))
POLL_SECONDS = float(os.getenv('CHAIN_POLL_SECONDS', '5'))
RECEIPT_TIMEOUT = timedelta(seconds=int(os.getenv('CHAIN_RECEIPT_TIMEOUT_SECONDS', '600')))
RETRY_BACKOFF_SECONDS = int(os.getenv('CHAIN_RETRY_BACKOFF_SECONDS', '30'))
BATCH = 50


def _now():
    return datetime.utcnow()


def _short_error(exc):
    """Safe to store: RPC errors can contain the provider URL, which holds the API key."""
    text = re.sub(r'https?://\S+', '<url>', f'{type(exc).__name__}: {exc}')
    return text[:300]


def _record_failure(complaint, message, *, final=False):
    """Count a failed attempt. Log phase: pending until the attempts run out."""
    complaint.chain_error = message[:300]
    if complaint.chain_status == 'confirmed':
        return  # status-sync failure: the report itself is fine; just stop retrying
    if final or (complaint.chain_attempts or 0) >= MAX_ATTEMPTS:
        complaint.chain_status = 'failed'
    else:
        complaint.chain_status = 'pending'


# ---------------------------------------------------------------------------
# Log transaction
# ---------------------------------------------------------------------------

def attempt_log(complaint, commit=True):
    """Broadcast logComplaint now. Returns as soon as the tx is sent.

    commit=False leaves the commit to the caller (the submit route does one
    commit for the insert and the tx hash, saving database round trips)."""
    complaint.chain_attempts = (complaint.chain_attempts or 0) + 1
    complaint.chain_sent_at = _now()
    complaint.blockchain_tx = None

    try:
        complaint.blockchain_tx = chain.log_complaint_on_chain(
            complaint.complaint_id, complaint.evidence_hash
        )
        complaint.chain_status = 'pending'
        complaint.chain_error = None
    except chain.GasCapExceeded as e:
        log.error('[chain] %s: %s', complaint.complaint_id, e)
        _record_failure(complaint, _short_error(e), final=True)
    except chain.ChainRevert as e:
        # Most likely "already logged" from an earlier tx that did get mined.
        record = _record_or_none(complaint.complaint_id)
        if record and record['evidence_hash'] == complaint.evidence_hash:
            complaint.chain_status = 'confirmed'
            complaint.chain_synced_status = record['status']
            complaint.chain_error = 'already on-chain (transaction hash not recorded)'
            complaint.chain_attempts = 0
        else:
            log.error('[chain] %s would revert: %s', complaint.complaint_id, e)
            _record_failure(complaint, _short_error(e))
    except Exception as e:  # RPC down, timeout, bad nonce...
        log.warning('[chain] %s send failed: %s', complaint.complaint_id, _short_error(e))
        _record_failure(complaint, _short_error(e))

    if commit:
        db.session.commit()


def _record_or_none(complaint_id):
    try:
        return chain.get_chain_record(complaint_id)
    except Exception:
        return None


def retry_log(complaint):
    """Owner-requested retry: fresh attempt budget."""
    complaint.chain_attempts = 0
    complaint.chain_error = None
    complaint.chain_status = 'pending'
    attempt_log(complaint)


def _check_log_receipt(complaint):
    receipt = chain.get_receipt(complaint.blockchain_tx)

    if receipt is None:
        if complaint.chain_sent_at and _now() - complaint.chain_sent_at > RECEIPT_TIMEOUT:
            complaint.blockchain_tx = None
            _record_failure(complaint, 'transaction was not mined in time')
            db.session.commit()
        return

    if receipt.status == 1:
        complaint.chain_status = 'confirmed'
        complaint.chain_synced_status = 'SUBMITTED'  # what logComplaint writes
        complaint.chain_error = None
        complaint.chain_attempts = 0
        log.info('[chain] %s confirmed (gas used %s)', complaint.complaint_id, receipt.gasUsed)
    else:
        log.error('[chain] %s reverted on-chain: %s', complaint.complaint_id, complaint.blockchain_tx)
        complaint.blockchain_tx = None
        _record_failure(complaint, 'logComplaint transaction reverted on-chain')
    db.session.commit()


# ---------------------------------------------------------------------------
# Status updates (admin PATCH -> updateStatus on-chain)
# ---------------------------------------------------------------------------

def needs_status_sync(complaint):
    return (
        complaint.chain_status == 'confirmed'
        and complaint.chain_synced_status != complaint.status
    )


def attempt_status_sync(complaint):
    target = complaint.status
    complaint.chain_attempts = (complaint.chain_attempts or 0) + 1
    complaint.chain_sent_at = _now()
    try:
        complaint.status_tx = chain.update_status_on_chain(complaint.complaint_id, target)
        complaint.status_tx_value = target
        complaint.chain_error = None
    except Exception as e:
        log.warning('[chain] %s status sync failed: %s', complaint.complaint_id, _short_error(e))
        complaint.status_tx = None
        complaint.status_tx_value = None
        complaint.chain_error = _short_error(e)
    db.session.commit()


def kick_status_sync(complaint):
    """Called after an admin changes the status: send updateStatus right away
    if the report is already on-chain; otherwise the worker does it later."""
    complaint.chain_attempts = 0
    if needs_status_sync(complaint) and not complaint.status_tx:
        attempt_status_sync(complaint)
    else:
        db.session.commit()


def _check_status_receipt(complaint):
    receipt = chain.get_receipt(complaint.status_tx)

    if receipt is None:
        if complaint.chain_sent_at and _now() - complaint.chain_sent_at > RECEIPT_TIMEOUT:
            complaint.status_tx = None
            complaint.status_tx_value = None
            complaint.chain_error = 'status transaction was not mined in time'
            db.session.commit()
        return

    if receipt.status == 1:
        complaint.chain_synced_status = complaint.status_tx_value
        complaint.chain_error = None
        complaint.chain_attempts = 0
        log.info('[chain] %s status -> %s confirmed (gas used %s)',
                 complaint.complaint_id, complaint.status_tx_value, receipt.gasUsed)
    else:
        complaint.chain_error = 'updateStatus transaction reverted on-chain'
    complaint.status_tx = None
    complaint.status_tx_value = None
    db.session.commit()


# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------

def _backoff_over(complaint):
    if not complaint.chain_sent_at:
        return True
    wait = RETRY_BACKOFF_SECONDS * max(1, complaint.chain_attempts or 1)
    return _now() - complaint.chain_sent_at >= timedelta(seconds=wait)


def adopt_legacy_rows():
    """Rows from before chain tracking existed (chain_status is NULL)."""
    rows = Complaint.query.filter(Complaint.chain_status.is_(None)).limit(200).all()
    adopted = 0
    for c in rows:
        if c.blockchain_tx:
            try:
                receipt = chain.get_receipt(c.blockchain_tx)
            except Exception:
                continue  # RPC trouble: try again on the next start
            if receipt is None:
                c.chain_status = 'pending'
                c.chain_sent_at = _now()
            elif receipt.status == 1:
                c.chain_status = 'confirmed'
                c.chain_synced_status = 'SUBMITTED'
            else:
                c.blockchain_tx = None
                c.chain_status = 'pending'
                c.chain_attempts = 0
        else:
            c.chain_status = 'pending'  # never logged: the worker will send it
            c.chain_attempts = 0
        adopted += 1
    db.session.commit()
    return adopted


def process_once():
    """One pass of the worker. Returns a small dict of counts (for logs/tests)."""
    counts = {'checked': 0, 'sent': 0}

    pending = (
        Complaint.query.filter(Complaint.chain_status == 'pending')
        .order_by(Complaint.id).limit(BATCH).all()
    )
    for c in pending:
        try:
            if c.blockchain_tx:
                counts['checked'] += 1
                _check_log_receipt(c)
            elif (c.chain_attempts or 0) < MAX_ATTEMPTS and _backoff_over(c):
                counts['sent'] += 1
                attempt_log(c)
            elif (c.chain_attempts or 0) >= MAX_ATTEMPTS:
                c.chain_status = 'failed'
                db.session.commit()
        except Exception as e:
            db.session.rollback()
            log.error('[chain] %s pass error: %s', c.complaint_id, _short_error(e))

    unsynced = (
        Complaint.query.filter(
            Complaint.chain_status == 'confirmed',
            or_(Complaint.chain_synced_status.is_(None),
                Complaint.chain_synced_status != Complaint.status),
        ).order_by(Complaint.id).limit(BATCH).all()
    )
    for c in unsynced:
        try:
            if c.status_tx:
                counts['checked'] += 1
                _check_status_receipt(c)
            elif (c.chain_attempts or 0) < MAX_ATTEMPTS and _backoff_over(c):
                counts['sent'] += 1
                attempt_status_sync(c)
        except Exception as e:
            db.session.rollback()
            log.error('[chain] %s status pass error: %s', c.complaint_id, _short_error(e))

    return counts


def _loop(app):
    with app.app_context():
        try:
            n = adopt_legacy_rows()
            if n:
                log.info('[chain] adopted %d older report(s)', n)
        except Exception as e:
            db.session.rollback()
            log.error('[chain] could not adopt older reports: %s', _short_error(e))

    while True:
        try:
            with app.app_context():
                process_once()
        except Exception as e:
            log.error('[chain] worker pass failed: %s', _short_error(e))
        time.sleep(POLL_SECONDS)


def start_worker(app):
    thread = threading.Thread(target=_loop, args=(app,), name='chain-worker', daemon=True)
    thread.start()
    return thread
