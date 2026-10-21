"""Tiny stdlib ABI encoder for the few dynamic signatures the keeper sends (no eth_abi needed in local mode)."""

from __future__ import annotations


def _w(v: int) -> bytes:
    return v.to_bytes(32, "big")


def _bytes(b: bytes) -> bytes:
    pad = (-len(b)) % 32
    return _w(len(b)) + b + b"\x00" * pad


def bytes_array(items: list[bytes]) -> bytes:
    """Tail encoding of a `bytes[]` value."""
    heads, tails, off = [], [], 32 * len(items)
    for it in items:
        heads.append(_w(off))
        t = _bytes(it)
        tails.append(t)
        off += len(t)
    return _w(len(items)) + b"".join(heads) + b"".join(tails)


def call_uint_bytes_array(selector: str, x: int, items: list[bytes]) -> str:
    """selector + abi.encode(uint256 x, bytes[] items)"""
    return selector + (_w(x) + _w(64) + bytes_array(items)).hex()


def call_bytes_array(selector: str, items: list[bytes]) -> str:
    """selector + abi.encode(bytes[] items)"""
    return selector + (_w(32) + bytes_array(items)).hex()


def signed_report(price_wad: int, publish_time: int, sig: bytes) -> bytes:
    """abi.encode(uint256 price, uint256 publishTime, bytes signature) — SignedPriceOracle.update element."""
    return _w(price_wad) + _w(publish_time) + _w(96) + _bytes(sig)


def report_hash(chain_id: int, oracle: str, price_wad: int, publish_time: int) -> bytes:
    """keccak256(abi.encode(chainid, oracle, price, publishTime)) — must match SignedPriceOracle.digest (pre-EIP-191)."""
    from eth_utils import keccak

    return keccak(_w(chain_id) + _w(int(oracle, 16)) + _w(price_wad) + _w(publish_time))
