import json
import os
from web3 import Web3

WEB3_PROVIDER_URL = os.getenv("WEB3_PROVIDER_URL")
CONTRACT_ADDRESS = os.getenv("CONTRACT_ADDRESS")
BACKEND_WALLET_PRIVATE_KEY = os.getenv("BACKEND_WALLET_PRIVATE_KEY")

_w3 = None
_contract = None


def get_contract():
    """Lazily builds a single reusable Web3 + contract instance."""
    global _w3, _contract
    if _contract is not None:
        return _w3, _contract

    _w3 = Web3(Web3.HTTPProvider(WEB3_PROVIDER_URL))

    abi_path = os.path.join(os.path.dirname(__file__), "contract_abi.json")
    with open(abi_path) as f:
        abi = json.load(f)

    _contract = _w3.eth.contract(address=Web3.to_checksum_address(CONTRACT_ADDRESS), abi=abi)
    return _w3, _contract


def log_complaint_on_chain(complaint_id: str, evidence_hash: str) -> str:
    """Signs and sends a logComplaint() transaction. Returns the transaction hash as a hex string.
    Raises on failure — caller decides how to handle a chain write failure."""
    w3, contract = get_contract()
    account = w3.eth.account.from_key(BACKEND_WALLET_PRIVATE_KEY)

    tx = contract.functions.logComplaint(complaint_id, evidence_hash).build_transaction({
        "from": account.address,
        "nonce": w3.eth.get_transaction_count(account.address),
        "gas": 200000,
        "gasPrice": w3.eth.gas_price,
        "chainId": 11155111,  # Sepolia
    })

    signed_tx = w3.eth.account.sign_transaction(tx, private_key=BACKEND_WALLET_PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.rawTransaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

    if receipt.status != 1:
        raise RuntimeError(f"On-chain logComplaint transaction reverted: {tx_hash.hex()}")

    return tx_hash.hex()
