// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RoleManager
/// @notice Central role registry for the MRO system.
/// @dev The system can never be left without an admin: the last admin cannot be revoked.
contract RoleManager {
    error NotAdmin();
    error ZeroAddress();
    error AlreadyGranted();
    error NotGranted();
    error InvalidRole();
    error LastAdmin();

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MRO_ROLE = keccak256("MRO_ROLE");
    bytes32 public constant ENGINEER_ROLE = keccak256("ENGINEER_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    mapping(bytes32 => mapping(address => bool)) private _hasRole;

    /// @notice Number of accounts currently holding ADMIN_ROLE.
    uint256 public adminCount;

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed by);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed by);

    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert ZeroAddress();
        _hasRole[ADMIN_ROLE][initialAdmin] = true;
        adminCount = 1;
        emit RoleGranted(ADMIN_ROLE, initialAdmin, msg.sender);
    }

    modifier onlyAdmin() {
        if (!_hasRole[ADMIN_ROLE][msg.sender]) revert NotAdmin();
        _;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _hasRole[role][account];
    }

    function grantRole(bytes32 role, address account) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        if (!_isValidRole(role)) revert InvalidRole();
        if (_hasRole[role][account]) revert AlreadyGranted();

        _hasRole[role][account] = true;
        if (role == ADMIN_ROLE) adminCount += 1;
        emit RoleGranted(role, account, msg.sender);
    }

    function revokeRole(bytes32 role, address account) external onlyAdmin {
        if (!_hasRole[role][account]) revert NotGranted();
        if (role == ADMIN_ROLE) {
            if (adminCount == 1) revert LastAdmin();
            adminCount -= 1;
        }

        _hasRole[role][account] = false;
        emit RoleRevoked(role, account, msg.sender);
    }

    function _isValidRole(bytes32 role) private pure returns (bool) {
        return role == ADMIN_ROLE || role == MRO_ROLE || role == ENGINEER_ROLE || role == AUDITOR_ROLE;
    }
}
