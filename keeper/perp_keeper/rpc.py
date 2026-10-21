"""Minimal JSON-RPC client (stdlib only). Read-only helpers + ABI word decoding."""

from __future__ import annotations

import json
import urllib.request
from dataclasses import dataclass
from typing import Any

WAD = 10**18


class RpcError(RuntimeError):
    def __init__(self, message: str, data: Any = None):
        super().__init__(message)
        self.data = data


@dataclass
class JsonRpc:
    url: str
    timeout: float = 15.0
    _id: int = 0

    def call(self, method: str, params: list | None = None) -> Any:
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or []}).encode()
        req = urllib.request.Request(self.url, data=body, headers={"Content-Type": "application/json", "User-Agent": "mezo-perp-keeper/0.1"})
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:  # noqa: S310 (operator-provided URL)
            payload = json.loads(resp.read())
        if "error" in payload:
            err = payload["error"]
            raise RpcError(err.get("message", str(err)), err.get("data"))
        return payload["result"]

    def chain_id(self) -> int:
        return int(self.call("eth_chainId"), 16)

    def eth_call(self, to: str, data: str) -> bytes:
        result = self.call("eth_call", [{"to": to, "data": data}, "latest"])
        return bytes.fromhex(result[2:])

    def block_timestamp(self) -> int:
        blk = self.call("eth_getBlockByNumber", ["latest", False])
        return int(blk["timestamp"], 16)


def words(raw: bytes) -> list[int]:
    """Split ABI-encoded static return data into uint256 words."""
    return [int.from_bytes(raw[i : i + 32], "big") for i in range(0, len(raw), 32)]


def to_signed(v: int) -> int:
    return v - (1 << 256) if v >= (1 << 255) else v


def fmt_wad(v: int, digits: int = 2) -> str:
    return f"{v / WAD:,.{digits}f}"
