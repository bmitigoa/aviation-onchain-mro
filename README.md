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

  * Admin
  * MRO (Maintenance Organization)
  * Licensed Engineer
  * Auditor (read-only)

* **Aircraft Registry**

  * Register aircraft (e.g. `5Y-ABC`)
  * Store model and operator details

* **Parts Registry**

  * Register serialized aircraft parts
  * Track lifecycle: Registered → Installed → Removed / Scrapped
  * Enforce aircraft–part relationships

* **Maintenance Log**

  * Log maintenance actions against aircraft and parts
  * Attach document hashes (e.g. IPFS CID or PDF hash)
  * Immutable event trail for audits

* **Fully Tested**

  * Unit tests cover authorization, lifecycle rules, and failure cases

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
├── src/        # Smart contracts
├── test/       # Foundry unit tests
├── script/     # Demo / deployment scripts
├── foundry.toml
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

All tests should pass.

---

## 🧪 Demo Scenario

The demo script shows a realistic workflow:

1. Admin assigns MRO and Engineer roles
2. Aircraft is registered
3. A serialized engine part is registered and installed
4. A maintenance event is logged with a document hash

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
