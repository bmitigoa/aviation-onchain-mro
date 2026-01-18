// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RoleManager.sol";

contract AircraftRegistry {
    error NotAuthorized();
    error EmptyString();
    error AircraftExists();

    struct Aircraft {
        string registration; // e.g. 5Y-ABC
        string model;        // e.g. B737-800
        string operatorName; // e.g. Kenya Airways
        uint64 createdAt;
        bool exists;
    }

    RoleManager public immutable roles;
    uint256 public aircraftCount;

    mapping(bytes32 => uint256) public aircraftIdByRegHash;
    mapping(uint256 => Aircraft) public aircraftById;

    event AircraftRegistered(
        uint256 indexed aircraftId,
        string registration,
        string model,
        string operatorName
    );

    constructor(RoleManager roleManager) {
        roles = roleManager;
    }

    modifier onlyAdminOrMRO() {
        bool ok =
            roles.hasRole(roles.ADMIN_ROLE(), msg.sender) ||
            roles.hasRole(roles.MRO_ROLE(), msg.sender);
        if (!ok) revert NotAuthorized();
        _;
    }

    function registerAircraft(
        string calldata registration,
        string calldata model,
        string calldata operatorName
    ) external onlyAdminOrMRO returns (uint256 aircraftId) {
        if (bytes(registration).length == 0) revert EmptyString();
        if (bytes(model).length == 0) revert EmptyString();
        if (bytes(operatorName).length == 0) revert EmptyString();

        bytes32 regHash = keccak256(bytes(registration));
        if (aircraftIdByRegHash[regHash] != 0) revert AircraftExists();

        aircraftCount += 1;
        aircraftId = aircraftCount;

        aircraftIdByRegHash[regHash] = aircraftId;
        aircraftById[aircraftId] = Aircraft({
            registration: registration,
            model: model,
            operatorName: operatorName,
            createdAt: uint64(block.timestamp),
            exists: true
        });

        emit AircraftRegistered(aircraftId, registration, model, operatorName);
    }

    function getAircraft(uint256 aircraftId) external view returns (Aircraft memory) {
        return aircraftById[aircraftId];
    }

    function exists(uint256 aircraftId) external view returns (bool) {
        return aircraftById[aircraftId].exists;
    }
}
