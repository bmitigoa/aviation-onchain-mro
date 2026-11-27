// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RoleManager} from "../src/RoleManager.sol";
import {AircraftRegistry} from "../src/AircraftRegistry.sol";
import {PartRegistry} from "../src/PartRegistry.sol";
import {MaintenanceLog} from "../src/MaintenanceLog.sol";

/// @notice Deploys the four contracts. The broadcaster becomes the initial admin.
/// forge script script/Deploy.s.sol:DeployScript --rpc-url <RPC> --private-key <KEY> --broadcast
contract DeployScript is Script {
    function run()
        public
        returns (RoleManager roles, AircraftRegistry aircraft, PartRegistry parts, MaintenanceLog mlog)
    {
        vm.startBroadcast();
        (, address admin,) = vm.readCallers();
        roles = new RoleManager(admin);
        aircraft = new AircraftRegistry(roles);
        parts = new PartRegistry(roles, aircraft);
        mlog = new MaintenanceLog(roles, aircraft, parts);
        vm.stopBroadcast();

        console.log("RoleManager      ", address(roles));
        console.log("AircraftRegistry ", address(aircraft));
        console.log("PartRegistry     ", address(parts));
        console.log("MaintenanceLog   ", address(mlog));
    }
}

/// @notice End-to-end demo against a local Anvil node, using Anvil's default accounts:
///         #0 admin, #1 MRO, #2 engineer, #3 auditor.
/// anvil   (in another terminal)
/// forge script script/Deploy.s.sol:DemoScript --rpc-url http://127.0.0.1:8545 --broadcast
contract DemoScript is Script {
    // Anvil's well-known development keys (never use on a real network).
    uint256 constant ADMIN_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant MRO_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant ENGINEER_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant AUDITOR_PK = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    function run() public {
        address admin = vm.addr(ADMIN_PK);
        address mro = vm.addr(MRO_PK);
        address engineer = vm.addr(ENGINEER_PK);
        address auditor = vm.addr(AUDITOR_PK);

        // 1. Admin deploys and assigns roles
        vm.startBroadcast(ADMIN_PK);
        RoleManager roles = new RoleManager(admin);
        AircraftRegistry aircraft = new AircraftRegistry(roles);
        PartRegistry parts = new PartRegistry(roles, aircraft);
        MaintenanceLog mlog = new MaintenanceLog(roles, aircraft, parts);
        roles.grantRole(roles.MRO_ROLE(), mro);
        roles.grantRole(roles.ENGINEER_ROLE(), engineer);
        roles.grantRole(roles.AUDITOR_ROLE(), auditor);
        vm.stopBroadcast();

        // 2-3. MRO registers the aircraft and installs a serialized engine
        vm.startBroadcast(MRO_PK);
        uint256 aId = aircraft.registerAircraft("5Y-ABC", "B737-800", "Demo Airline");
        bytes32 engine = parts.registerPart("CFM56-7B", "SN-ENG-0001", "CFM International");
        parts.installPart(aId, engine);
        vm.stopBroadcast();

        // 4. Engineer logs maintenance with a document hash, then corrects it via amendment
        vm.startBroadcast(ENGINEER_PK);
        uint256 logId = mlog.logMaintenance(aId, engine, "Borescope inspection", "QmExampleWorkCardCid");
        mlog.amendMaintenance(logId, "Borescope inspection - HPT stage 1 noted", "QmExampleWorkCardCidV2");
        vm.stopBroadcast();

        // 5. Auditor flags the original entry for review
        vm.startBroadcast(AUDITOR_PK);
        mlog.flagRecord(logId, "Superseded by amendment; verify work card");
        vm.stopBroadcast();

        console.log("MaintenanceLog   ", address(mlog));
        console.log("Log entries      ", mlog.count());
    }
}
