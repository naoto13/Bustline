// Parity check vs Python (keeper/perp_keeper abi.py + eth_account) using a PUBLIC dummy key (anvil #1), never the keeper key.
import { encodeAbiParameters, keccak256, serializeTransaction } from "viem";
import { privateKeyToAccount } from "viem/accounts";
const K = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a84112f6c79f4f8f9d4";
const acct = privateKeyToAccount(K);
const ORACLE = "0x83401Fc1B16DbCa09531241Dad49700248C8c72c";
const price = 80638123456780000000000n, t = 1793000000;
const h = keccak256(encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }], [31611n, BigInt(ORACLE), price, BigInt(t)]));
const sig = await acct.signMessage({ message: { raw: h } });
const rep = encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }, { type: "bytes" }], [price, BigInt(t), sig]);
const push = "0x066f2eb6" + encodeAbiParameters([{ type: "bytes[]" }], [[rep]]).slice(2);
const exe = "0x33e7dddb" + encodeAbiParameters([{ type: "uint256" }, { type: "bytes[]" }], [3n, [rep]]).slice(2);
const raw = await acct.signTransaction({ type: "legacy", chainId: 31611, to: "0x5e941EEA56DEE50924950E86f24624Be37f02050", data: push, value: 0n, gas: 300000n, gasPrice: 292n, nonce: 7 });
console.log(JSON.stringify({ h, sig, push, exe, raw }));
