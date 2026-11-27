# Aviation On-Chain MRO (Maintenance & Parts Traceability)

A smart contract–based system for **tamper-proof aircraft maintenance records and serialized part traceability**, built with **Solidity and Foundry**.

This project demonstrates how blockchain can be used to improve **auditability, safety, and trust** in aviation Maintenance, Repair, and Overhaul (MRO) operations.

---

## ✈️ Problem Context

In aviation:

* Aircraft parts must be traceable by **serial number**
* Maintenance records must be **accurate, immutable, and auditable**
* Counterfeit or undocumented parts pose serious **safety and regulatory risks**
* Audits are often manual, slow, and fragmented across systems

Traditional databases allow records to be modified. This project explores how **on-chain immutability** can address these challenges.

---

## ⛓️ Solution Overview

The system provides an **on-chain ledger** for:

* Aircraft registration
* Serialized part lifecycle management
* Maintenance event logging by authorized personnel

All critical actions are enforced through **role-based access control** and recorded as **immutable blockchain events**.

---

## 🔑 Core Features

* **Role-Based Access Control**

  * Admin – manages roles; the last admin can never be revoked (no lock-out)
  * MRO (Maintenance Organization) – registers aircraft and parts, installs/removes/scraps parts
  * Licensed Engineer – logs and amends maintenance records
  * Auditor – flags records for review (flags are permanent and public)

* **Aircraft Registry**

  * Register aircraft (e.g. `5Y-ABC`)
  * Store model and operator details

* **Parts Registry**

  * Parts are identified by `partId = keccak256(abi.encode(manufacturer, partNumber, serialNumber))`, since serial numbers are only unique per manufacturer and part number
  * Enforced lifecycle (see rules below)
  * Enforce aircraft–part relationships

* **Maintenance Log (append-only)**

  * Log maintenance against a part **installed on that aircraft**, or off-wing shop work (`aircraftId = 0`) on a removed / newly registered part
  * Each entry stores the **SHA-256 of its supporting document** plus an optional storage URI (e.g. `ipfs://…`)
  * Engineers can **sign records off-chain (EIP-712)** and a relayer submits them
  * Corrections are **amendments**: new entries that reference the original, which stays unchanged
  * Immutable event trail for audits

* **Batch Anchoring**

  * Anchor a whole maintenance package (e.g. a C-check with hundreds of task cards) as **one Merkle root**
  * Prove any single task card belongs to the package without revealing the rest

* **Tested**

  * 59 unit and fuzz tests covering authorization, lifecycle rules, signatures, Merkle proofs, events and failure cases
  * Invariant tests that drive random install / remove / scrap sequences

---

## 🔁 Part Lifecycle Rules

```
REGISTERED ──install──▶ INSTALLED ──remove──▶ REMOVED ──scrap──▶ SCRAPPED (terminal)
                            ▲                    │
                            └──────install───────┘
REGISTERED ──scrap──▶ SCRAPPED
```

| Rule | Enforced by |
| --- | --- |
| A scrapped part can never be reinstalled | `PartIsScrapped` |
| An installed part must be removed before scrapping (so the aircraft history shows the removal) | `MustRemoveBeforeScrap` |
| A part is on at most one aircraft at a time | `AlreadyInstalled` |
| Maintenance on an aircraft must reference a part installed on it | `PartNotOnAircraft` |
| Shop work cannot target an installed or scrapped part | `PartNotAvailableForShopWork` |

---

## 🔐 Cryptographic Traceability

| Mechanism | What it proves | Where |
| --- | --- | --- |
| **SHA-256 document hashes** | A work card / PDF is byte-for-byte the document that was signed off | `MaintenanceLog.verifyDocument` |
| **EIP-712 typed signatures** | A specific licensed engineer approved exactly this record (aircraft, part, action, document) | `MaintenanceLog.logMaintenanceBySig` |
| **Nonces + deadlines** | A signature can be used once, and only before it expires (no replay) | OpenZeppelin `Nonces` |
| **ERC-1271 support** | Sign-off can come from a smart-contract wallet (e.g. an MRO multisig) | OpenZeppelin `SignatureChecker` |
| **Merkle batch anchoring** | A task card is part of an anchored maintenance package | `BatchAnchor.verifyItem` |
| **Hash-keyed identities** | Part IDs bind manufacturer, part number and serial without collisions | `PartRegistry.partKey` |

**Gasless engineer sign-off.** The engineer signs the record with their key (no transaction, no gas). Anyone, typically the MRO's relayer, submits it. The record stores both the accountable `engineer` and the `submitter`. Authority comes from the signature, and the signer must still hold a valid role at submission time, so revoking an engineer also invalidates their unsubmitted signatures.

EIP-712 type signed by engineers:

```
MaintenanceRecord(uint256 aircraftId,bytes32 partId,string action,bytes32 docHash,string docUri,uint256 nonce,uint256 deadline)
Domain: name "AviationMRO MaintenanceLog", version "1", chainId, verifyingContract
```

**Merkle leaves** use the OpenZeppelin `StandardMerkleTree` encoding, so off-chain trees verify on-chain unchanged:

```
leaf = keccak256(bytes.concat(keccak256(abi.encode(partId, taskRef, docHash))))
```

A test (`testBatch_VerifiesEveryItemFromOffChainTree`) checks every proof generated by `tools/build-batch.mjs` against the contract, and CI regenerates the example tree to make sure the two stay in sync.

### Limitations (threat model)

* **Garbage in, garbage out.** The chain proves *who* recorded *what* and *when*, not that the physical work was done correctly. It complements, not replaces, the MRO's quality system.
* **Key custody.** Security depends on engineers protecting their signing keys. Contract wallets (ERC-1271) allow multisig or hardware-backed keys.
* **Timestamps** are set by block producers and are accurate to within seconds, not milliseconds.
* **Confidentiality.** Only hashes and short descriptions go on-chain. Full documents stay off-chain (e.g. IPFS or the MRO's document system). For commercially sensitive fleets, a permissioned EVM network is the intended deployment.

---

## 🛠️ Off-chain Tools

`tools/` (Node.js 18+, run `npm install` inside it):

```bash
# SHA-256 of a document (same result as sha256sum), the on-chain docHash
node tools/hash-doc.mjs workcard.pdf

# Build a Merkle tree for a maintenance package -> root + per-item proofs
node tools/build-batch.mjs tools/examples/c-check-package.json out.json

# Engineer signs a record off-chain; --relay submits it with RELAYER_KEY
ENGINEER_KEY=0x.. RELAYER_KEY=0x.. RPC_URL=http://127.0.0.1:8545 MAINTENANCE_LOG=0x.. \
  node tools/sign-record.mjs record.json --relay
```

---

## 🧱 Architecture

**Smart Contracts**

* `RoleManager.sol` – Manages system roles and permissions
* `AircraftRegistry.sol` – Aircraft registration and lookup
* `PartRegistry.sol` – Serialized part lifecycle management
* `MaintenanceLog.sol` – Append-only maintenance records, EIP-712 sign-off, document verification
* `BatchAnchor.sol` – Merkle-root anchoring of maintenance packages

**Design Principles**

* Events-first (easy off-chain indexing)
* Minimal on-chain storage
* Clear separation of responsibilities

---

## 🛠️ Tech Stack

* **Solidity** (≥ 0.8.x)
* **Foundry** (forge, anvil)
* **OpenZeppelin Contracts v5** (EIP712, SignatureChecker, Nonces, MerkleProof)
* **Node.js + viem + @openzeppelin/merkle-tree** for off-chain signing and batch building
* **EVM-compatible networks** (local Anvil, testnets, or permissioned chains)

---

## 📁 Project Structure

```
aviation-onchain-mro/
├── src/
│   ├── RoleManager.sol
│   ├── AircraftRegistry.sol
│   ├── PartRegistry.sol
│   ├── MaintenanceLog.sol
│   └── BatchAnchor.sol
├── test/
│   ├── AviationMRO.t.sol              # unit + fuzz tests
│   ├── Cryptography.t.sol             # EIP-712, ERC-1271, document + Merkle tests
│   └── PartLifecycle.invariant.t.sol  # invariant tests
├── tools/                             # hash-doc, build-batch, sign-record (Node.js)
│   └── examples/                      # sample C-check package + generated tree
├── script/
│   └── Deploy.s.sol                   # DeployScript + DemoScript
├── foundry.toml
└── LICENSE
```

---

## 🚀 Getting Started

### Prerequisites

* Foundry installed (`forge --version`)
* Git (clone with `--recursive` to fetch `lib/` dependencies)
* Node.js 18+ (only for `tools/`)

### Build

```bash
forge build
```

### Run Tests

```bash
forge test -v
```

All tests should pass. CI (GitHub Actions) runs `forge fmt --check`, `forge build` and `forge test` on every push, with more fuzz and invariant runs under the `ci` profile.

### Deploy

```bash
forge script script/Deploy.s.sol:DeployScript --rpc-url <RPC_URL> --private-key <KEY> --broadcast
```

The deploying account becomes the initial admin.

---

## 🧪 Demo Scenario

Run the full workflow on a local Anvil node:

```bash
anvil   # in another terminal
forge script script/Deploy.s.sol:DemoScript --rpc-url http://127.0.0.1:8545 --broadcast
```

1. Admin deploys the contracts and assigns MRO, Engineer and Auditor roles
2. MRO registers aircraft `5Y-ABC`
3. MRO registers and installs a serialized engine
4. Engineer **signs a maintenance record off-chain (EIP-712)**; the MRO relays it, so the engineer pays no gas
5. MRO anchors a 5-task C-check package as a single Merkle root
6. Engineer corrects the record with an amendment (original unchanged)
7. Auditor flags the original entry for review, and the work card's SHA-256 is verified on-chain

This mirrors real-world MRO operations.

---

## 🔮 Future Enhancements

* IPFS pinning service integration for maintenance documents
* Release-certificate hashes (EASA Form 1 / FAA 8130-3) at part registration
* Life-limited part tracking (flight hours and cycles)
* Dual sign-off for Required Inspection Items
* QR / NFC tagging for physical part verification
* Frontend dashboard for regulators and auditors
* Deployment on permissioned EVM networks for enterprise use
* Integration with ESG and compliance reporting systems

---

## 👨‍💻 Purpose

This project was built as:

* A **portfolio project** for blockchain / smart contract engineering
* A foundation for further research into blockchain applications in aviation

---

## 📄 License

MIT
