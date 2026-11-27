// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import "./RoleManager.sol";
import "./AircraftRegistry.sol";
import "./PartRegistry.sol";

/// @title MaintenanceLog
/// @notice Append-only maintenance record with cryptographic sign-off.
/// @dev - Entries are never edited or deleted: corrections are amendments that reference
///        the original, and auditors can flag entries for review.
///      - Each entry stores the SHA-256 digest of its supporting document (work card, CRS, PDF),
///        so anyone holding the file can prove it is the exact document that was signed off.
///      - Engineers can sign records off-chain with EIP-712; anyone (e.g. the MRO's relayer)
///        can submit them, so engineers never need gas. ERC-1271 smart-contract wallets
///        are supported via SignatureChecker. Nonces and deadlines prevent replay.
contract MaintenanceLog is EIP712, Nonces {
    error NotAuthorized();
    error EmptyString();
    error EmptyDocHash();
    error AircraftNotFound();
    error PartNotFound();
    error PartNotOnAircraft();
    error PartNotAvailableForShopWork();
    error LogNotFound();
    error AlreadyFlagged();
    error SignatureExpired();
    error InvalidSignature();

    /// @dev aircraftId == 0 means off-wing (shop) work on a removed or newly registered part.
    struct MaintenanceEvent {
        uint256 aircraftId;
        bytes32 partId;
        string action;
        bytes32 docHash; // SHA-256 of the supporting document
        string docUri; // where the document is stored, e.g. ipfs://<CID> (optional)
        address engineer; // the accountable signer
        address submitter; // the account that sent the transaction (== engineer unless relayed)
        uint64 timestamp;
        bool isAmendment;
        uint256 amendsLogId; // only meaningful when isAmendment == true
    }

    /// @dev Input bundle for a new record (keeps the stack shallow).
    struct Record {
        uint256 aircraftId;
        bytes32 partId;
        string action;
        bytes32 docHash;
        string docUri;
    }

    bytes32 public constant MAINTENANCE_RECORD_TYPEHASH = keccak256(
        "MaintenanceRecord(uint256 aircraftId,bytes32 partId,string action,bytes32 docHash,string docUri,uint256 nonce,uint256 deadline)"
    );

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
        bytes32 docHash,
        string docUri,
        address engineer,
        address submitter
    );
    event MaintenanceAmended(uint256 indexed logId, uint256 indexed amendsLogId, address indexed engineer);
    event RecordFlagged(uint256 indexed logId, address indexed auditor, string reason);

    constructor(RoleManager roleManager, AircraftRegistry aircraftRegistry, PartRegistry partRegistry)
        EIP712("AviationMRO MaintenanceLog", "1")
    {
        roles = roleManager;
        aircraft = aircraftRegistry;
        parts = partRegistry;
    }

    modifier onlyAuditor() {
        _onlyAuditor();
        _;
    }

    // ------------------------------------------------------------------ write

    /// @notice Log a maintenance action, signed by the transaction itself.
    function logMaintenance(Record calldata r) external returns (uint256 logId) {
        _requireCanSign(msg.sender);
        _validate(r);
        logId = _append(r, msg.sender, false, 0);
    }

    /// @notice Submit a record that an engineer signed off-chain (EIP-712).
    /// @param engineer The signer; must hold ENGINEER, MRO or ADMIN role.
    /// @param deadline Unix time after which the signature is no longer valid.
    /// @param signature 65-byte ECDSA signature, or ERC-1271 data for contract wallets.
    function logMaintenanceBySig(Record calldata r, address engineer, uint256 deadline, bytes calldata signature)
        external
        returns (uint256 logId)
    {
        if (block.timestamp > deadline) revert SignatureExpired();
        _requireCanSign(engineer);
        _validate(r);

        bytes32 digest = recordDigest(r, _useNonce(engineer), deadline);
        if (!SignatureChecker.isValidSignatureNow(engineer, digest, signature)) revert InvalidSignature();

        logId = _append(r, engineer, false, 0);
    }

    /// @notice Correct an earlier entry by appending a new one that references it.
    ///         The original stays on record unchanged.
    function amendMaintenance(uint256 originalLogId, string calldata action, bytes32 docHash, string calldata docUri)
        external
        returns (uint256 logId)
    {
        _requireCanSign(msg.sender);
        if (originalLogId >= logs.length) revert LogNotFound();
        if (bytes(action).length == 0) revert EmptyString();
        if (docHash == bytes32(0)) revert EmptyDocHash();

        MaintenanceEvent storage o = logs[originalLogId];
        Record memory r =
            Record({aircraftId: o.aircraftId, partId: o.partId, action: action, docHash: docHash, docUri: docUri});
        logId = _append(r, msg.sender, true, originalLogId);
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

    // ------------------------------------------------------------------ read

    /// @notice True if `docHash` (SHA-256 of a file) is the document recorded for `logId`.
    function verifyDocument(uint256 logId, bytes32 docHash) external view returns (bool) {
        if (logId >= logs.length) revert LogNotFound();
        return logs[logId].docHash == docHash;
    }

    /// @notice EIP-712 digest an engineer signs for `r` with the given nonce and deadline.
    function recordDigest(Record memory r, uint256 nonce, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    MAINTENANCE_RECORD_TYPEHASH,
                    r.aircraftId,
                    r.partId,
                    keccak256(bytes(r.action)),
                    r.docHash,
                    keccak256(bytes(r.docUri)),
                    nonce,
                    deadline
                )
            )
        );
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
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

    // ------------------------------------------------------------------ internal

    function _requireCanSign(address who) private view {
        bool ok = roles.hasRole(roles.ADMIN_ROLE(), who) || roles.hasRole(roles.MRO_ROLE(), who)
            || roles.hasRole(roles.ENGINEER_ROLE(), who);
        if (!ok) revert NotAuthorized();
    }

    function _onlyAuditor() private view {
        if (!roles.hasRole(roles.AUDITOR_ROLE(), msg.sender)) revert NotAuthorized();
    }

    function _validate(Record calldata r) private view {
        if (bytes(r.action).length == 0) revert EmptyString();
        if (r.docHash == bytes32(0)) revert EmptyDocHash();
        if (!parts.partExists(r.partId)) revert PartNotFound();

        if (r.aircraftId == 0) {
            PartRegistry.PartStatus s = parts.statusOf(r.partId);
            if (s == PartRegistry.PartStatus.INSTALLED || s == PartRegistry.PartStatus.SCRAPPED) {
                revert PartNotAvailableForShopWork();
            }
        } else {
            if (!aircraft.exists(r.aircraftId)) revert AircraftNotFound();
            if (!parts.isInstalledOn(r.partId, r.aircraftId)) revert PartNotOnAircraft();
        }
    }

    function _append(Record memory r, address engineer, bool isAmendment, uint256 amendsLogId)
        private
        returns (uint256 logId)
    {
        logs.push(
            MaintenanceEvent({
                aircraftId: r.aircraftId,
                partId: r.partId,
                action: r.action,
                docHash: r.docHash,
                docUri: r.docUri,
                engineer: engineer,
                submitter: msg.sender,
                timestamp: uint64(block.timestamp),
                isAmendment: isAmendment,
                amendsLogId: amendsLogId
            })
        );
        logId = logs.length - 1;

        emit MaintenanceLogged(logId, r.aircraftId, r.partId, r.action, r.docHash, r.docUri, engineer, msg.sender);
    }
}
