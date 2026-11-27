// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RoleManager.sol";
import "./AircraftRegistry.sol";

/// @title PartRegistry
/// @notice Serialized part lifecycle: REGISTERED -> INSTALLED <-> REMOVED -> SCRAPPED,
///         with release certificates and life-limited part (LLP) tracking.
/// @dev - Parts are identified by partId = keccak256(abi.encode(manufacturer, partNumber, serialNumber)),
///        because serial numbers are only unique per manufacturer and part number.
///      - SCRAPPED is a terminal state: a scrapped part can never return to service.
///      - Every part carries the SHA-256 of its current authorised release certificate
///        (EASA Form 1 / FAA 8130-3). A new certificate is recorded after each shop visit.
///      - Life-limited parts have an hour and/or cycle limit (0 = no limit). Usage accrues
///        while installed, and a part at or past either limit cannot be installed.
contract PartRegistry {
    error NotAuthorized();
    error EmptyString();
    error EmptyCertificate();
    error PartExists();
    error PartNotFound();
    error AircraftNotFound();
    error AlreadyInstalled();
    error NotInstalledOnThatAircraft();
    error NotInstalled();
    error PartIsScrapped();
    error MustRemoveBeforeScrap();
    error LifeLimitReached();
    error CertificateWhileInstalled();

    enum PartStatus {
        REGISTERED,
        INSTALLED,
        REMOVED,
        SCRAPPED
    }

    /// @notice Registration input (keeps the external ABI and stack manageable).
    struct PartInput {
        string partNumber;
        string serialNumber;
        string manufacturer;
        bytes32 releaseCertHash; // SHA-256 of the EASA Form 1 / FAA 8130-3
        uint32 hourLimit; // 0 = not hour-limited
        uint32 cycleLimit; // 0 = not cycle-limited
        uint32 hoursSinceNew; // for used parts entering the registry
        uint32 cyclesSinceNew;
    }

    struct Part {
        string partNumber;
        string serialNumber;
        string manufacturer;
        PartStatus status;
        uint256 installedAircraftId; // 0 if not installed
        uint64 updatedAt;
        bool exists;
        bytes32 releaseCertHash;
        uint32 hourLimit;
        uint32 cycleLimit;
        uint32 hoursSinceNew;
        uint32 cyclesSinceNew;
    }

    RoleManager public immutable roles;
    AircraftRegistry public immutable aircraft;

    mapping(bytes32 => Part) private partsById;

    event PartRegistered(
        bytes32 indexed partId, string manufacturer, string partNumber, string serialNumber, address indexed by
    );
    event ReleaseCertificateRecorded(bytes32 indexed partId, bytes32 indexed certHash, address indexed by);
    event LifeLimitsSet(bytes32 indexed partId, uint32 hourLimit, uint32 cycleLimit);
    event PartInstalled(bytes32 indexed partId, uint256 indexed aircraftId, address indexed by);
    event PartRemoved(bytes32 indexed partId, uint256 indexed aircraftId, address indexed by);
    event PartScrapped(bytes32 indexed partId, address indexed by);
    event UsageRecorded(
        bytes32 indexed partId, uint32 flightHours, uint32 flightCycles, uint32 hoursSinceNew, uint32 cyclesSinceNew
    );
    event LifeLimitExceeded(bytes32 indexed partId, uint32 hoursSinceNew, uint32 cyclesSinceNew);

    constructor(RoleManager roleManager, AircraftRegistry aircraftRegistry) {
        roles = roleManager;
        aircraft = aircraftRegistry;
    }

    modifier onlyAdminOrMRO() {
        _onlyAdminOrMRO();
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

    // ------------------------------------------------------------------ registration & certificates

    function registerPart(PartInput calldata input) external onlyAdminOrMRO returns (bytes32 partId) {
        if (bytes(input.partNumber).length == 0) revert EmptyString();
        if (bytes(input.serialNumber).length == 0) revert EmptyString();
        if (bytes(input.manufacturer).length == 0) revert EmptyString();
        if (input.releaseCertHash == bytes32(0)) revert EmptyCertificate();

        partId = partKey(input.manufacturer, input.partNumber, input.serialNumber);
        if (partsById[partId].exists) revert PartExists();

        partsById[partId] = Part({
            partNumber: input.partNumber,
            serialNumber: input.serialNumber,
            manufacturer: input.manufacturer,
            status: PartStatus.REGISTERED,
            installedAircraftId: 0,
            updatedAt: uint64(block.timestamp),
            exists: true,
            releaseCertHash: input.releaseCertHash,
            hourLimit: input.hourLimit,
            cycleLimit: input.cycleLimit,
            hoursSinceNew: input.hoursSinceNew,
            cyclesSinceNew: input.cyclesSinceNew
        });

        emit PartRegistered(partId, input.manufacturer, input.partNumber, input.serialNumber, msg.sender);
        emit ReleaseCertificateRecorded(partId, input.releaseCertHash, msg.sender);
        if (input.hourLimit != 0 || input.cycleLimit != 0) {
            emit LifeLimitsSet(partId, input.hourLimit, input.cycleLimit);
        }
    }

    /// @notice Record a new release certificate, e.g. after a shop overhaul.
    ///         Only for parts off-wing and not scrapped. Earlier certificates remain in the event history.
    function recordReleaseCertificate(bytes32 partId, bytes32 certHash) external onlyAdminOrMRO {
        if (certHash == bytes32(0)) revert EmptyCertificate();
        Part storage p = _existing(partId);
        if (p.status == PartStatus.SCRAPPED) revert PartIsScrapped();
        if (p.status == PartStatus.INSTALLED) revert CertificateWhileInstalled();

        p.releaseCertHash = certHash;
        p.updatedAt = uint64(block.timestamp);
        emit ReleaseCertificateRecorded(partId, certHash, msg.sender);
    }

    // ------------------------------------------------------------------ lifecycle

    function installPart(uint256 aircraftId, bytes32 partId) external onlyAdminOrMRO {
        if (!aircraft.exists(aircraftId)) revert AircraftNotFound();

        Part storage p = _existing(partId);
        if (p.status == PartStatus.SCRAPPED) revert PartIsScrapped();
        if (p.status == PartStatus.INSTALLED) revert AlreadyInstalled();
        if (_lifeExpired(p)) revert LifeLimitReached();

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

    // ------------------------------------------------------------------ life-limited parts

    /// @notice Record flight hours and cycles flown by installed parts (e.g. all parts on one aircraft
    ///         after a flight or a day's operations). Usage is recorded as flown, even past a limit,
    ///         so the record stays truthful; LifeLimitExceeded is emitted when a limit is reached.
    function recordUsage(bytes32[] calldata partIds, uint32 flightHours, uint32 flightCycles) external onlyAdminOrMRO {
        for (uint256 i; i < partIds.length; i++) {
            Part storage p = _existing(partIds[i]);
            if (p.status != PartStatus.INSTALLED) revert NotInstalled();

            bool wasExpired = _lifeExpired(p);
            p.hoursSinceNew += flightHours;
            p.cyclesSinceNew += flightCycles;
            p.updatedAt = uint64(block.timestamp);

            emit UsageRecorded(partIds[i], flightHours, flightCycles, p.hoursSinceNew, p.cyclesSinceNew);
            if (!wasExpired && _lifeExpired(p)) {
                emit LifeLimitExceeded(partIds[i], p.hoursSinceNew, p.cyclesSinceNew);
            }
        }
    }

    /// @notice Remaining life. type(uint32).max means that dimension is not limited.
    function remainingLife(bytes32 partId) external view returns (uint32 hoursLeft, uint32 cyclesLeft) {
        Part storage p = _existing(partId);
        hoursLeft = _remaining(p.hourLimit, p.hoursSinceNew);
        cyclesLeft = _remaining(p.cycleLimit, p.cyclesSinceNew);
    }

    function isLifeExpired(bytes32 partId) external view returns (bool) {
        return _lifeExpired(_existing(partId));
    }

    // ------------------------------------------------------------------ views

    /// @notice True if `certHash` (SHA-256 of a certificate file) is the part's current release certificate.
    function verifyReleaseCertificate(bytes32 partId, bytes32 certHash) external view returns (bool) {
        return _existing(partId).releaseCertHash == certHash;
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

    // ------------------------------------------------------------------ internal

    function _onlyAdminOrMRO() private view {
        bool ok = roles.hasRole(roles.ADMIN_ROLE(), msg.sender) || roles.hasRole(roles.MRO_ROLE(), msg.sender);
        if (!ok) revert NotAuthorized();
    }

    function _existing(bytes32 partId) private view returns (Part storage p) {
        p = partsById[partId];
        if (!p.exists) revert PartNotFound();
    }

    function _lifeExpired(Part storage p) private view returns (bool) {
        return
            (p.hourLimit != 0 && p.hoursSinceNew >= p.hourLimit)
                || (p.cycleLimit != 0 && p.cyclesSinceNew >= p.cycleLimit);
    }

    function _remaining(uint32 limit, uint32 used) private pure returns (uint32) {
        if (limit == 0) return type(uint32).max;
        return used >= limit ? 0 : limit - used;
    }
}
