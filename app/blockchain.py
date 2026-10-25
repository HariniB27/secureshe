"""Sepolia access for the SecureSheRegistry contract.

Nothing in here waits for a transaction to be mined: the send functions
return the transaction hash as soon as it is broadcast. Confirming (or
retrying) is app/chain_sync.py's job.
"""
import json
import os
import threading

from web3 import Web3
from web3.exceptions import ContractLogicError, TransactionNotFound

CHAIN_ID = 11155111  # Sepolia


class ChainError(Exception):
    """Base class for chain problems the caller should record, not crash on."""


class GasCapExceeded(ChainError):
    """The gas estimate (with headroom) is above CHAIN_MAX_GAS. Deterministic,
    so retrying the same transaction would fail the same way."""


class ChainRevert(ChainError):
    """The node says the call would revert (e.g. the complaint is already logged)."""


_w3 = None
_contract = None
# Estimate, nonce and send happen under one lock so two requests can't be
# handed the same pending nonce.
_send_lock = threading.Lock()


def gas_multiplier():
    return float(os.getenv('CHAIN_GAS_MULTIPLIER', '1.3'))


def max_gas():
    return int(os.getenv('CHAIN_MAX_GAS', '3000000'))


def gas_price_multiplier():
    # Small margin so a base-fee tick between quoting and inclusion doesn't strand the tx.
    return float(os.getenv('CHAIN_GAS_PRICE_MULTIPLIER', '1.25'))


def get_contract():
    """Lazily builds a single reusable Web3 + contract instance."""
    global _w3, _contract
    if _contract is not None:
        return _w3, _contract

    provider = Web3.HTTPProvider(
        os.getenv('WEB3_PROVIDER_URL'),
        request_kwargs={'timeout': int(os.getenv('CHAIN_RPC_TIMEOUT_SECONDS', '15'))},
    )
    _w3 = Web3(provider)

    abi_path = os.path.join(os.path.dirname(__file__), 'contract_abi.json')
    with open(abi_path) as f:
        abi = json.load(f)

    _contract = _w3.eth.contract(
        address=Web3.to_checksum_address(os.getenv('CONTRACT_ADDRESS')), abi=abi
    )
    return _w3, _contract


def _send(contract_fn):
    """Estimate gas, sign and broadcast. Returns the tx hash (0x...)."""
    w3, _ = get_contract()
    key = os.getenv('BACKEND_WALLET_PRIVATE_KEY')
    account = w3.eth.account.from_key(key)

    with _send_lock:
        try:
            estimate = contract_fn.estimate_gas({'from': account.address})
        except ContractLogicError as e:
            raise ChainRevert(str(e)) from e

        gas = int(estimate * gas_multiplier())
        if gas > max_gas():
            raise GasCapExceeded(
                f'gas estimate {estimate} x {gas_multiplier()} = {gas} exceeds the cap {max_gas()}'
            )

        tx = contract_fn.build_transaction({
            'from': account.address,
            # 'pending' counts transactions we've already broadcast but that aren't mined yet.
            'nonce': w3.eth.get_transaction_count(account.address, 'pending'),
            'gas': gas,
            'gasPrice': int(w3.eth.gas_price * gas_price_multiplier()),
            'chainId': CHAIN_ID,
        })
        signed = w3.eth.account.sign_transaction(tx, private_key=key)
        tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)

    return Web3.to_hex(tx_hash)


def log_complaint_on_chain(complaint_id: str, evidence_hash: str) -> str:
    _, contract = get_contract()
    return _send(contract.functions.logComplaint(complaint_id, evidence_hash))


def update_status_on_chain(complaint_id: str, status: str) -> str:
    _, contract = get_contract()
    return _send(contract.functions.updateStatus(complaint_id, status))


def get_receipt(tx_hash: str):
    """The receipt, or None if the transaction isn't mined yet."""
    w3, _ = get_contract()
    try:
        return w3.eth.get_transaction_receipt(tx_hash)
    except TransactionNotFound:
        return None


def get_chain_record(complaint_id: str):
    """What the contract holds for this id, or None if it was never logged."""
    _, contract = get_contract()
    evidence_hash, timestamp, status, exists = contract.functions.getComplaint(complaint_id).call()
    if not exists:
        return None
    return {'evidence_hash': evidence_hash, 'timestamp': timestamp, 'status': status}
