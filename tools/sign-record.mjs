// Engineer signs a maintenance record off-chain (EIP-712); a relayer can submit it.
//
// Usage:
//   ENGINEER_KEY=0x.. RPC_URL=http://127.0.0.1:8545 MAINTENANCE_LOG=0x.. \
//   node sign-record.mjs <record.json> [--relay]
//
// record.json: { "aircraftId": 1, "partId": "0x..", "action": "...", "docHash": "0x..", "docUri": "ipfs://..." }
// Optional env: DEADLINE_SECONDS (default 3600).
// With --relay, RELAYER_KEY submits the signed record via logMaintenanceBySig.
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const [file, flag] = process.argv.slice(2);
const { ENGINEER_KEY, RELAYER_KEY, RPC_URL, MAINTENANCE_LOG } = process.env;
if (!file || !ENGINEER_KEY || !RPC_URL || !MAINTENANCE_LOG) {
  console.error("Usage: ENGINEER_KEY=.. RPC_URL=.. MAINTENANCE_LOG=.. node sign-record.mjs <record.json> [--relay]");
  process.exit(1);
}

const abi = parseAbi([
  "function nonces(address owner) view returns (uint256)",
  "function logMaintenanceBySig((uint256 aircraftId, bytes32 partId, string action, bytes32 docHash, string docUri) r, address engineer, uint256 deadline, bytes signature) returns (uint256)",
]);

const raw = JSON.parse(readFileSync(file, "utf8"));
const record = {
  aircraftId: BigInt(raw.aircraftId),
  partId: raw.partId,
  action: raw.action,
  docHash: raw.docHash,
  docUri: raw.docUri ?? "",
};

const transport = http(RPC_URL);
const client = createPublicClient({ transport });
const chainId = await client.getChainId();
const engineer = privateKeyToAccount(ENGINEER_KEY);

const nonce = await client.readContract({ address: MAINTENANCE_LOG, abi, functionName: "nonces", args: [engineer.address] });
const deadline = BigInt(Math.floor(Date.now() / 1000) + Number(process.env.DEADLINE_SECONDS ?? 3600));

// Must match MaintenanceLog: EIP712("AviationMRO MaintenanceLog", "1") and MAINTENANCE_RECORD_TYPEHASH
const signature = await engineer.signTypedData({
  domain: { name: "AviationMRO MaintenanceLog", version: "1", chainId, verifyingContract: MAINTENANCE_LOG },
  types: {
    MaintenanceRecord: [
      { name: "aircraftId", type: "uint256" },
      { name: "partId", type: "bytes32" },
      { name: "action", type: "string" },
      { name: "docHash", type: "bytes32" },
      { name: "docUri", type: "string" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  },
  primaryType: "MaintenanceRecord",
  message: { ...record, nonce, deadline },
});

console.log(JSON.stringify({ engineer: engineer.address, nonce: nonce.toString(), deadline: deadline.toString(), signature }, null, 2));

if (flag === "--relay") {
  if (!RELAYER_KEY) {
    console.error("--relay needs RELAYER_KEY");
    process.exit(1);
  }
  const relayer = privateKeyToAccount(RELAYER_KEY);
  const wallet = createWalletClient({ account: relayer, transport });
  const hash = await wallet.writeContract({
    address: MAINTENANCE_LOG,
    abi,
    functionName: "logMaintenanceBySig",
    args: [record, engineer.address, deadline, signature],
    chain: { id: chainId, name: "custom", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC_URL] } } },
  });
  const receipt = await client.waitForTransactionReceipt({ hash });
  console.log(`relayed by ${relayer.address}: ${hash} (${receipt.status})`);
}
