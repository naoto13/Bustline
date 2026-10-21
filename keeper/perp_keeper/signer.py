"""Mezo TESTNET signer. Reads MEZO_TESTNET_PRIVATE_KEY from the environment at call time only.

Why not forge/cast: forge scripts simulate locally first and the forked EVM cannot execute Mezo's Skip oracle
precompile (EvmError: NotActivated), and cast only accepts the key on argv. This signer keeps the key out of argv,
logs and files. Requires `eth-account` (keeper/.venv, see docs/TESTNET-DEPLOY.md).
Guards: RPC host must be rpc.test.mezo.org and chainId must be 31611.
"""

from __future__ import annotations

import os
import time
from typing import Optional
from urllib.parse import urlparse

from .rpc import JsonRpc, RpcError

TESTNET_HOSTS = {"rpc.test.mezo.org"}
CHAIN_ID = 31611
ENV_KEY = "MEZO_TESTNET_PRIVATE_KEY"


class SignerRefused(RuntimeError):
    pass


def selector(sig: str) -> str:
    from eth_utils import keccak

    return "0x" + keccak(text=sig)[:4].hex()


def calldata(sig: str, types: list[str], args: list) -> str:
    from eth_abi import encode

    return selector(sig) + encode(types, args).hex()


class EnvSigner:
    def __init__(self, rpc: JsonRpc):
        self.rpc = rpc
        self.check()
        from eth_account import Account

        self._acct = Account.from_key(os.environ[ENV_KEY])  # key stays in memory only
        self.address: str = self._acct.address

    def check(self) -> None:
        host = urlparse(self.rpc.url).hostname or ""
        if host not in TESTNET_HOSTS:
            raise SignerRefused(f"refusing: '{host}' is not the Mezo testnet RPC")
        if self.rpc.chain_id() != CHAIN_ID:
            raise SignerRefused("refusing: chainId is not 31611")
        if not os.environ.get(ENV_KEY):
            raise SignerRefused(f"refusing: {ENV_KEY} not set")

    def send(self, to: str, data: str, value: int = 0, gas: Optional[int] = None) -> dict:
        self.check()
        tx = {"from": self.address, "to": to, "data": data, "value": hex(value)}
        if gas is None:
            gas = int(int(self.rpc.call("eth_estimateGas", [tx]), 16) * 13 // 10) + 20_000
        nonce = int(self.rpc.call("eth_getTransactionCount", [self.address, "pending"]), 16)
        gas_price = max(int(self.rpc.call("eth_gasPrice"), 16) * 2, 1_000)
        signed = self._acct.sign_transaction(
            {"to": to, "data": data, "value": value, "gas": gas, "gasPrice": gas_price, "nonce": nonce, "chainId": CHAIN_ID}
        )
        raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
        h = self.rpc.call("eth_sendRawTransaction", ["0x" + raw.hex().removeprefix("0x")])
        for _ in range(120):
            try:
                rc = self.rpc.call("eth_getTransactionReceipt", [h])
            except (RpcError, OSError):  # flaky public RPC: keep polling
                rc = None
            if rc:
                if int(rc["status"], 16) != 1:
                    raise RpcError(f"tx reverted: {h}")
                return rc
            time.sleep(1)
        raise RpcError(f"no receipt after 120s: {h}")
