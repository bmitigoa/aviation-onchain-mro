// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RoleManager.sol";
import "./AircraftRegistry.sol";
import "./PartRegistry.sol";

contract MaintenanceLog {
    error NotAuthorized();
    error EmptyString();
    error AircraftNotFound();
    error PartNotFound();

    struct MaintenanceEvent {
        uint256 aircraftId;
        string partSerial;
        string action;
        string docHash;    // IPFS CID or PDF hash
        address engineer;
        uint64 timestamp;
    }

    RoleManager public immutable roles;
    AircraftRegistry public immutable aircraft;
    PartRegistry public immutable parts;

    MaintenanceEvent[] private logs;

    event MaintenanceLogged(
        uint256 indexed logId,
        uint256 indexed aircraftId,
        string partSerial,
        string action,
        string docHash,
        address indexed engineer
    );

    constructor(RoleManager roleManager, AircraftRegistry aircraftRegistry, PartRegistry partRegistry) {
        roles = roleManager;
        aircraft = aircraftRegistry;
        parts = partRegistry;
    }

    modifier onlyEngineerOrMROOrAdmin() {
        bool ok =
            roles.hasRole(roles.ADMIN_ROLE(), msg.sender) ||
            roles.hasRole(roles.MRO_ROLE(), msg.sender) ||
            roles.hasRole(roles.ENGINEER_ROLE(), msg.sender);
        if (!ok) revert NotAuthorized();
        _;
    }

    function logMaintenance(
        uint256 aircraftId,
        string calldata partSerial,
        string calldata action,
        string calldata docHash
    ) external onlyEngineerOrMROOrAdmin returns (uint256 logId) {
        if (!aircraft.exists(aircraftId)) revert AircraftNotFound();
        if (bytes(partSerial).length == 0) revert EmptyString();
        if (bytes(action).length == 0) revert EmptyString();
        if (bytes(docHash).length == 0) revert EmptyString();
        if (!parts.partExists(partSerial)) revert PartNotFound();

        logs.push(MaintenanceEvent({
            aircraftId: aircraftId,
            partSerial: partSerial,
            action: action,
            docHash: docHash,
            engineer: msg.sender,
            timestamp: uint64(block.timestamp)
        }));

        logId = logs.length - 1;

        emit MaintenanceLogged(logId, aircraftId, partSerial, action, docHash, msg.sender);
    }

    function count() external view returns (uint256) {
        return logs.length;
    }

    function get(uint256 logId) external view returns (MaintenanceEvent memory) {
        return logs[logId];
    }
}
