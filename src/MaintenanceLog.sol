// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RoleManager.sol";
import "./AircraftRegistry.sol";
import "./PartRegistry.sol";

/// @title MaintenanceLog
/// @notice Append-only maintenance record. Entries are never edited or deleted:
///         corrections are new entries that reference the original (amendments),
///         and auditors can flag entries for review.
contract MaintenanceLog {
    error NotAuthorized();
    error EmptyString();
    error AircraftNotFound();
    error PartNotFound();
    error PartNotOnAircraft();
    error PartNotAvailableForShopWork();
    error LogNotFound();
    error AlreadyFlagged();

    /// @dev aircraftId == 0 means off-wing (shop) work on a removed or newly registered part.
    struct MaintenanceEvent {
        uint256 aircraftId;
        bytes32 partId;
        string action;
        string docHash; // IPFS CID or PDF hash
        address engineer;
        uint64 timestamp;
        bool isAmendment;
        uint256 amendsLogId; // only meaningful when isAmendment == true
    }

    RoleManager public immutable roles;
    AircraftRegistry public immutable aircraft;
    PartRegistry public immutable parts;

    MaintenanceEvent[] private logs;
    mapping(uint256 => uint256[]) private _amendments;
    mapping(uint256 => bool) public flagged;

    event MaintenanceLogged(
        uint256 indexed logId,
        uint256 indexed aircraftId,
        bytes32 indexed partId,
        string action,
        string docHash,
        address engineer
    );
    event MaintenanceAmended(uint256 indexed logId, uint256 indexed amendsLogId, address indexed engineer);
    event RecordFlagged(uint256 indexed logId, address indexed auditor, string reason);

    constructor(RoleManager roleManager, AircraftRegistry aircraftRegistry, PartRegistry partRegistry) {
        roles = roleManager;
        aircraft = aircraftRegistry;
        parts = partRegistry;
    }

    modifier onlyEngineerOrMROOrAdmin() {
        bool ok = roles.hasRole(roles.ADMIN_ROLE(), msg.sender) || roles.hasRole(roles.MRO_ROLE(), msg.sender)
            || roles.hasRole(roles.ENGINEER_ROLE(), msg.sender);
        if (!ok) revert NotAuthorized();
        _;
    }

    modifier onlyAuditor() {
        if (!roles.hasRole(roles.AUDITOR_ROLE(), msg.sender)) revert NotAuthorized();
        _;
    }

    /// @notice Log a maintenance action.
    /// @param aircraftId Aircraft the part is installed on, or 0 for off-wing shop work.
    function logMaintenance(uint256 aircraftId, bytes32 partId, string calldata action, string calldata docHash)
        external
        onlyEngineerOrMROOrAdmin
        returns (uint256 logId)
    {
        _validate(aircraftId, partId, action, docHash);
        logId = _append(aircraftId, partId, action, docHash, false, 0);
    }

    /// @notice Correct an earlier entry by appending a new one that references it.
    ///         The original stays on record unchanged.
    function amendMaintenance(uint256 originalLogId, string calldata action, string calldata docHash)
        external
        onlyEngineerOrMROOrAdmin
        returns (uint256 logId)
    {
        if (originalLogId >= logs.length) revert LogNotFound();
        if (bytes(action).length == 0) revert EmptyString();
        if (bytes(docHash).length == 0) revert EmptyString();

        MaintenanceEvent storage original = logs[originalLogId];
        logId = _append(original.aircraftId, original.partId, action, docHash, true, originalLogId);
        _amendments[originalLogId].push(logId);

        emit MaintenanceAmended(logId, originalLogId, msg.sender);
    }

    /// @notice Auditors flag a record for review. Flags are permanent and public.
    function flagRecord(uint256 logId, string calldata reason) external onlyAuditor {
        if (logId >= logs.length) revert LogNotFound();
        if (bytes(reason).length == 0) revert EmptyString();
        if (flagged[logId]) revert AlreadyFlagged();

        flagged[logId] = true;
        emit RecordFlagged(logId, msg.sender, reason);
    }

    function count() external view returns (uint256) {
        return logs.length;
    }

    function get(uint256 logId) external view returns (MaintenanceEvent memory) {
        if (logId >= logs.length) revert LogNotFound();
        return logs[logId];
    }

    function amendmentsOf(uint256 logId) external view returns (uint256[] memory) {
        return _amendments[logId];
    }

    function _validate(uint256 aircraftId, bytes32 partId, string calldata action, string calldata docHash)
        private
        view
    {
        if (bytes(action).length == 0) revert EmptyString();
        if (bytes(docHash).length == 0) revert EmptyString();
        if (!parts.partExists(partId)) revert PartNotFound();

        if (aircraftId == 0) {
            PartRegistry.PartStatus s = parts.statusOf(partId);
            if (s == PartRegistry.PartStatus.INSTALLED || s == PartRegistry.PartStatus.SCRAPPED) {
                revert PartNotAvailableForShopWork();
            }
        } else {
            if (!aircraft.exists(aircraftId)) revert AircraftNotFound();
            if (!parts.isInstalledOn(partId, aircraftId)) revert PartNotOnAircraft();
        }
    }

    function _append(
        uint256 aircraftId,
        bytes32 partId,
        string calldata action,
        string calldata docHash,
        bool isAmendment,
        uint256 amendsLogId
    ) private returns (uint256 logId) {
        logs.push(
            MaintenanceEvent({
                aircraftId: aircraftId,
                partId: partId,
                action: action,
                docHash: docHash,
                engineer: msg.sender,
                timestamp: uint64(block.timestamp),
                isAmendment: isAmendment,
                amendsLogId: amendsLogId
            })
        );
        logId = logs.length - 1;

        emit MaintenanceLogged(logId, aircraftId, partId, action, docHash, msg.sender);
    }
}
