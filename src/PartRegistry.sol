// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RoleManager.sol";
import "./AircraftRegistry.sol";

contract PartRegistry {
    error NotAuthorized();
    error EmptyString();
    error PartExists();
    error PartNotFound();
    error AircraftNotFound();
    error AlreadyInstalled();
    error NotInstalledOnThatAircraft();

    enum PartStatus { REGISTERED, INSTALLED, REMOVED, SCRAPPED }

    struct Part {
        string partNumber;
        string serialNumber;
        string manufacturer;
        PartStatus status;
        uint256 installedAircraftId; // 0 if not installed
        uint64 updatedAt;
        bool exists;
    }

    RoleManager public immutable roles;
    AircraftRegistry public immutable aircraft;

    mapping(bytes32 => Part) private partsBySerialHash;

    event PartRegistered(string partNumber, string serialNumber, string manufacturer);
    event PartInstalled(string serialNumber, uint256 indexed aircraftId);
    event PartRemoved(string serialNumber, uint256 indexed aircraftId);
    event PartScrapped(string serialNumber);

    constructor(RoleManager roleManager, AircraftRegistry aircraftRegistry) {
        roles = roleManager;
        aircraft = aircraftRegistry;
    }

    modifier onlyAdminOrMRO() {
        bool ok =
            roles.hasRole(roles.ADMIN_ROLE(), msg.sender) ||
            roles.hasRole(roles.MRO_ROLE(), msg.sender);
        if (!ok) revert NotAuthorized();
        _;
    }

    function registerPart(
        string calldata partNumber,
        string calldata serialNumber,
        string calldata manufacturer
    ) external onlyAdminOrMRO {
        if (bytes(partNumber).length == 0) revert EmptyString();
        if (bytes(serialNumber).length == 0) revert EmptyString();
        if (bytes(manufacturer).length == 0) revert EmptyString();

        bytes32 s = keccak256(bytes(serialNumber));
        if (partsBySerialHash[s].exists) revert PartExists();

        partsBySerialHash[s] = Part({
            partNumber: partNumber,
            serialNumber: serialNumber,
            manufacturer: manufacturer,
            status: PartStatus.REGISTERED,
            installedAircraftId: 0,
            updatedAt: uint64(block.timestamp),
            exists: true
        });

        emit PartRegistered(partNumber, serialNumber, manufacturer);
    }

    function installPart(uint256 aircraftId, string calldata serialNumber) external onlyAdminOrMRO {
        if (!aircraft.exists(aircraftId)) revert AircraftNotFound();

        bytes32 s = keccak256(bytes(serialNumber));
        Part storage p = partsBySerialHash[s];
        if (!p.exists) revert PartNotFound();
        if (p.status == PartStatus.INSTALLED) revert AlreadyInstalled();

        p.status = PartStatus.INSTALLED;
        p.installedAircraftId = aircraftId;
        p.updatedAt = uint64(block.timestamp);

        emit PartInstalled(serialNumber, aircraftId);
    }

    function removePart(uint256 aircraftId, string calldata serialNumber) external onlyAdminOrMRO {
        bytes32 s = keccak256(bytes(serialNumber));
        Part storage p = partsBySerialHash[s];
        if (!p.exists) revert PartNotFound();
        if (p.status != PartStatus.INSTALLED || p.installedAircraftId != aircraftId) {
            revert NotInstalledOnThatAircraft();
        }

        p.status = PartStatus.REMOVED;
        p.installedAircraftId = 0;
        p.updatedAt = uint64(block.timestamp);

        emit PartRemoved(serialNumber, aircraftId);
    }

    function scrapPart(string calldata serialNumber) external onlyAdminOrMRO {
        bytes32 s = keccak256(bytes(serialNumber));
        Part storage p = partsBySerialHash[s];
        if (!p.exists) revert PartNotFound();

        p.status = PartStatus.SCRAPPED;
        p.installedAircraftId = 0;
        p.updatedAt = uint64(block.timestamp);

        emit PartScrapped(serialNumber);
    }

    function getPart(string calldata serialNumber) external view returns (Part memory) {
        bytes32 s = keccak256(bytes(serialNumber));
        return partsBySerialHash[s];
    }

    function partExists(string calldata serialNumber) external view returns (bool) {
        bytes32 s = keccak256(bytes(serialNumber));
        return partsBySerialHash[s].exists;
    }
}
