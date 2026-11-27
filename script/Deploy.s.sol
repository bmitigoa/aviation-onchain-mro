// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RoleManager} from "../src/RoleManager.sol";
import {AircraftRegistry} from "../src/AircraftRegistry.sol";
import {PartRegistry} from "../src/PartRegistry.sol";
import {MaintenanceLog} from "../src/MaintenanceLog.sol";
import {BatchAnchor} from "../src/BatchAnchor.sol";

/// @notice Deploys the contracts. The broadcaster becomes the initial admin.
/// forge script script/Deploy.s.sol:DeployScript --rpc-url <RPC> --private-key <KEY> --broadcast
contract DeployScript is Script {
    function run()
        public
        returns (
            RoleManager roles,
            AircraftRegistry aircraft,
            PartRegistry parts,
            MaintenanceLog mlog,
            BatchAnchor anchor
        )
    {
        vm.startBroadcast();
        (, address admin,) = vm.readCallers();
        roles = new RoleManager(admin);
        aircraft = new AircraftRegistry(roles);
        parts = new PartRegistry(roles, aircraft);
        mlog = new MaintenanceLog(roles, aircraft, parts);
        anchor = new BatchAnchor(roles, aircraft);
        vm.stopBroadcast();

        console.log("RoleManager      ", address(roles));
        console.log("AircraftRegistry ", address(aircraft));
        console.log("PartRegistry     ", address(parts));
        console.log("MaintenanceLog   ", address(mlog));
        console.log("BatchAnchor      ", address(anchor));
    }
}

/// @notice End-to-end demo against a local Anvil node, using Anvil's default accounts:
///         #0 admin, #1 MRO (also the relayer), #2 engineer, #3 auditor.
/// anvil   (in another terminal)
/// forge script script/Deploy.s.sol:DemoScript --rpc-url http://127.0.0.1:8545 --broadcast
contract DemoScript is Script {
    // Anvil's well-known development keys (never use on a real network).
    uint256 constant ADMIN_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant MRO_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant ENGINEER_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant AUDITOR_PK = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    // Root of tools/examples/c-check-package.json, built with tools/build-batch.mjs
    bytes32 constant C_CHECK_ROOT = 0x31d1635c6e9657c787cff4574da33c0b7964c717be6a929b502e40f3bd486d46;

    struct Deployed {
        RoleManager roles;
        AircraftRegistry aircraft;
        PartRegistry parts;
        MaintenanceLog mlog;
        BatchAnchor anchor;
    }

    function run() public {
        Deployed memory d = _deployAndAssignRoles();

        // 2-3. MRO registers the aircraft and installs a serialized engine
        vm.startBroadcast(MRO_PK);
        uint256 aId = d.aircraft.registerAircraft("5Y-ABC", "B737-800", "Demo Airline");
        bytes32 engine = d.parts.registerPart("CFM56-7B", "SN-ENG-0001", "CFM International");
        d.parts.installPart(aId, engine);
        vm.stopBroadcast();

        // 4-5. Engineer signs off-chain; MRO relays it and anchors a C-check package
        uint256 logId = _relaySignedRecord(d, aId, engine);

        // 6. Engineer corrects the record via an amendment (original stays unchanged)
        vm.startBroadcast(ENGINEER_PK);
        d.mlog
            .amendMaintenance(
                logId, "Borescope inspection - HPT stage 1 noted", sha256("Work card WC-0001 rev B"), "ipfs://QmRevB"
            );
        vm.stopBroadcast();

        // 7. Auditor flags the original entry for review
        vm.startBroadcast(AUDITOR_PK);
        d.mlog.flagRecord(logId, "Superseded by amendment; verify work card");
        vm.stopBroadcast();

        console.log("MaintenanceLog   ", address(d.mlog));
        console.log("BatchAnchor      ", address(d.anchor));
        console.log("Log entries      ", d.mlog.count());
        console.log("Doc rev A valid  ", d.mlog.verifyDocument(logId, sha256("Work card WC-0001 rev A")));
    }

    /// 1. Admin deploys and assigns roles
    function _deployAndAssignRoles() internal returns (Deployed memory d) {
        vm.startBroadcast(ADMIN_PK);
        d.roles = new RoleManager(vm.addr(ADMIN_PK));
        d.aircraft = new AircraftRegistry(d.roles);
        d.parts = new PartRegistry(d.roles, d.aircraft);
        d.mlog = new MaintenanceLog(d.roles, d.aircraft, d.parts);
        d.anchor = new BatchAnchor(d.roles, d.aircraft);
        d.roles.grantRole(d.roles.MRO_ROLE(), vm.addr(MRO_PK));
        d.roles.grantRole(d.roles.ENGINEER_ROLE(), vm.addr(ENGINEER_PK));
        d.roles.grantRole(d.roles.AUDITOR_ROLE(), vm.addr(AUDITOR_PK));
        vm.stopBroadcast();
    }

    /// 4. Engineer signs the record OFF-CHAIN (EIP-712, no gas); the MRO relays it.
    /// 5. The MRO anchors a whole C-check package as one Merkle root.
    function _relaySignedRecord(Deployed memory d, uint256 aId, bytes32 engine) internal returns (uint256 logId) {
        address engineer = vm.addr(ENGINEER_PK);
        MaintenanceLog.Record memory r = MaintenanceLog.Record({
            aircraftId: aId,
            partId: engine,
            action: "Borescope inspection",
            docHash: sha256("Work card WC-0001 rev A"),
            docUri: "ipfs://QmExampleWorkCard"
        });
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = d.mlog.recordDigest(r, d.mlog.nonces(engineer), deadline);
        (uint8 v, bytes32 rs, bytes32 s) = vm.sign(ENGINEER_PK, digest);

        vm.startBroadcast(MRO_PK);
        logId = d.mlog.logMaintenanceBySig(r, engineer, deadline, abi.encodePacked(rs, s, v));
        d.anchor.anchorBatch(aId, C_CHECK_ROOT, 5, "ipfs://QmExampleCCheckPackage");
        vm.stopBroadcast();
    }
}
