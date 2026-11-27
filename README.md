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
  * Attach document hashes (e.g. IPFS CID or PDF hash)
  * Corrections are **amendments**: new entries that reference the original, which stays unchanged
  * Immutable event trail for audits

* **Tested**

  * 40 unit and fuzz tests covering authorization, lifecycle rules, events and failure cases
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

## 🧱 Architecture

**Smart Contracts**

* `RoleManager.sol` – Manages system roles and permissions
* `AircraftRegistry.sol` – Aircraft registration and lookup
* `PartRegistry.sol` – Serialized part lifecycle management
* `MaintenanceLog.sol` – Maintenance event logging

**Design Principles**

* Events-first (easy off-chain indexing)
* Minimal on-chain storage
* Clear separation of responsibilities

---

## 🛠️ Tech Stack

* **Solidity** (≥ 0.8.x)
* **Foundry** (forge, anvil)
* **EVM-compatible networks** (local Anvil, testnets, or permissioned chains)

---

## 📁 Project Structure

```
aviation-onchain-mro/
├── src/
│   ├── RoleManager.sol
│   ├── AircraftRegistry.sol
│   ├── PartRegistry.sol
│   └── MaintenanceLog.sol
├── test/
│   ├── AviationMRO.t.sol              # unit + fuzz tests
│   └── PartLifecycle.invariant.t.sol  # invariant tests
├── script/
│   └── Deploy.s.sol                   # DeployScript + DemoScript
├── foundry.toml
└── LICENSE
```

---

## 🚀 Getting Started

### Prerequisites

* Foundry installed (`forge --version`)
* Git

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
4. Engineer logs a maintenance event with a document hash, then corrects it with an amendment
5. Auditor flags the original entry for review

This mirrors real-world MRO operations.

---

## 🔮 Future Enhancements

* IPFS integration for signed maintenance documents
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
