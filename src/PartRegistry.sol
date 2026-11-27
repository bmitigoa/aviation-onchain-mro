// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RoleManager.sol";
import "./AircraftRegistry.sol";

/// @title PartRegistry
/// @notice Serialized part lifecycle: REGISTERED -> INSTALLED <-> REMOVED -> SCRAPPED.
/// @dev Parts are identified by partId = keccak256(abi.encode(manufacturer, partNumber, serialNumber)),
///      because serial numbers are only unique per manufacturer and part number.
///      SCRAPPED is a terminal state: a scrapped part can never return to service.
contract PartRegistry {
    error NotAuthorized();
    error EmptyString();
    error PartExists();
    error PartNotFound();
    error AircraftNotFound();
    error AlreadyInstalled();
    error NotInstalledOnThatAircraft();
    error PartIsScrapped();
    error MustRemoveBeforeScrap();

    enum PartStatus {
        REGISTERED,
        INSTALLED,
        REMOVED,
        SCRAPPED
    }

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

    mapping(bytes32 => Part) private partsById;

    event PartRegistered(
        bytes32 indexed partId, string manufacturer, string partNumber, string serialNumber, address indexed by
    );
    event PartInstalled(bytes32 indexed partId, uint256 indexed aircraftId, address indexed by);
    event PartRemoved(bytes32 indexed partId, uint256 indexed aircraftId, address indexed by);
    event PartScrapped(bytes32 indexed partId, address indexed by);

    constructor(RoleManager roleManager, AircraftRegistry aircraftRegistry) {
        roles = roleManager;
        aircraft = aircraftRegistry;
    }

    modifier onlyAdminOrMRO() {
        bool ok = roles.hasRole(roles.ADMIN_ROLE(), msg.sender) || roles.hasRole(roles.MRO_ROLE(), msg.sender);
        if (!ok) revert NotAuthorized();
        _;
    }

    /// @notice Deterministic part identifier.
    function partKey(string memory manufacturer, string memory partNumber, string memory serialNumber)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(manufacturer, partNumber, serialNumber));
    }

    function registerPart(string calldata partNumber, string calldata serialNumber, string calldata manufacturer)
        external
        onlyAdminOrMRO
        returns (bytes32 partId)
    {
        if (bytes(partNumber).length == 0) revert EmptyString();
        if (bytes(serialNumber).length == 0) revert EmptyString();
        if (bytes(manufacturer).length == 0) revert EmptyString();

        partId = partKey(manufacturer, partNumber, serialNumber);
        if (partsById[partId].exists) revert PartExists();

        partsById[partId] = Part({
            partNumber: partNumber,
            serialNumber: serialNumber,
            manufacturer: manufacturer,
            status: PartStatus.REGISTERED,
            installedAircraftId: 0,
            updatedAt: uint64(block.timestamp),
            exists: true
        });

        emit PartRegistered(partId, manufacturer, partNumber, serialNumber, msg.sender);
    }

    function installPart(uint256 aircraftId, bytes32 partId) external onlyAdminOrMRO {
        if (!aircraft.exists(aircraftId)) revert AircraftNotFound();

        Part storage p = _existing(partId);
        if (p.status == PartStatus.SCRAPPED) revert PartIsScrapped();
        if (p.status == PartStatus.INSTALLED) revert AlreadyInstalled();

        p.status = PartStatus.INSTALLED;
        p.installedAircraftId = aircraftId;
        p.updatedAt = uint64(block.timestamp);

        emit PartInstalled(partId, aircraftId, msg.sender);
    }

    function removePart(uint256 aircraftId, bytes32 partId) external onlyAdminOrMRO {
        Part storage p = _existing(partId);
        if (p.status != PartStatus.INSTALLED || p.installedAircraftId != aircraftId) {
            revert NotInstalledOnThatAircraft();
        }

        p.status = PartStatus.REMOVED;
        p.installedAircraftId = 0;
        p.updatedAt = uint64(block.timestamp);

        emit PartRemoved(partId, aircraftId, msg.sender);
    }

    /// @notice Permanently retire a part. It must be removed from any aircraft first,
    ///         so the aircraft's history always shows an explicit removal.
    function scrapPart(bytes32 partId) external onlyAdminOrMRO {
        Part storage p = _existing(partId);
        if (p.status == PartStatus.SCRAPPED) revert PartIsScrapped();
        if (p.status == PartStatus.INSTALLED) revert MustRemoveBeforeScrap();

        p.status = PartStatus.SCRAPPED;
        p.updatedAt = uint64(block.timestamp);

        emit PartScrapped(partId, msg.sender);
    }

    function getPart(bytes32 partId) external view returns (Part memory) {
        return partsById[partId];
    }

    function partExists(bytes32 partId) external view returns (bool) {
        return partsById[partId].exists;
    }

    function statusOf(bytes32 partId) external view returns (PartStatus) {
        return _existing(partId).status;
    }

    function isInstalledOn(bytes32 partId, uint256 aircraftId) external view returns (bool) {
        Part storage p = partsById[partId];
        return p.exists && p.status == PartStatus.INSTALLED && p.installedAircraftId == aircraftId;
    }

    function _existing(bytes32 partId) private view returns (Part storage p) {
        p = partsById[partId];
        if (!p.exists) revert PartNotFound();
    }
}
