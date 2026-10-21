"""ABI encodings checked against forge's `cast` (if available) and the signer round-trip (needs keeper/.venv)."""

import shutil
import subprocess
import unittest

from perp_keeper.abi import call_bytes_array, call_uint_bytes_array, signed_report

CAST = shutil.which("cast") or shutil.which(str(__import__("pathlib").Path.home() / ".foundry/bin/cast"))


@unittest.skipUnless(CAST, "cast not installed")
class CastParity(unittest.TestCase):
    def cast(self, *a):
        return subprocess.run([CAST, *a], check=True, capture_output=True, text=True).stdout.strip()

    def test_execute_order_calldata(self):
        items = [b"\x01\x02\x03", b"\xff" * 40]
        want = self.cast("calldata", "executeOrder(uint256,bytes[])", "7", "[0x010203,0x" + "ff" * 40 + "]")
        got = call_uint_bytes_array(want[:10], 7, items)
        self.assertEqual(got, want)

    def test_push_calldata_empty_and_one(self):
        want = self.cast("calldata", "pushPrice(bytes[])", "[]")
        self.assertEqual(call_bytes_array(want[:10], []), want)
        want = self.cast("calldata", "pushPrice(bytes[])", "[0xabcd]")
        self.assertEqual(call_bytes_array(want[:10], [b"\xab\xcd"]), want)

    def test_signed_report_encoding(self):
        sig = bytes(range(65))
        want = self.cast("abi-encode", "f(uint256,uint256,bytes)", "5", "6", "0x" + sig.hex())
        self.assertEqual("0x" + signed_report(5, 6, sig).hex(), want)


try:
    import eth_account  # noqa: F401

    HAVE_ETH = True
except ImportError:
    HAVE_ETH = False


@unittest.skipUnless(HAVE_ETH, "eth-account not installed (keeper/.venv)")
class SignerRoundTrip(unittest.TestCase):
    def test_report_signature_recovers_to_signer(self):
        from eth_account import Account
        from eth_account.messages import encode_defunct

        from perp_keeper.abi import report_hash
        from perp_keeper.prices import UPDATE_FEE_SEL
        from perp_keeper.signer import selector

        acct = Account.create()  # throwaway in-memory test key, never persisted
        h = report_hash(31611, "0x" + "11" * 20, 80_000 * 10**18, 1_800_000_000)
        sig = bytes(acct.sign_message(encode_defunct(primitive=h)).signature)
        self.assertEqual(Account.recover_message(encode_defunct(primitive=h), signature=sig), acct.address)
        self.assertEqual(UPDATE_FEE_SEL, selector("updateFee(bytes[])"))
