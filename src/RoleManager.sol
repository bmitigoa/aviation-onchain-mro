// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract RoleManager {
    error NotAdmin();
    error ZeroAddress();
    error AlreadyAdmin();
    error NotGranted();
    error InvalidRole();

    bytes32 public constant ADMIN_ROLE    = keccak256("ADMIN_ROLE");
    bytes32 public constant MRO_ROLE      = keccak256("MRO_ROLE");
    bytes32 public constant ENGINEER_ROLE = keccak256("ENGINEER_ROLE");
    bytes32 public constant AUDITOR_ROLE  = keccak256("AUDITOR_ROLE");

    mapping(bytes32 => mapping(address => bool)) private _hasRole;

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed by);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed by);

    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert ZeroAddress();
        _hasRole[ADMIN_ROLE][initialAdmin] = true;
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
        if (
            role != ADMIN_ROLE &&
            role != MRO_ROLE &&
            role != ENGINEER_ROLE &&
            role != AUDITOR_ROLE
        ) revert InvalidRole();

        if (_hasRole[role][account]) {
            if (role == ADMIN_ROLE) revert AlreadyAdmin();
            return;
        }

        _hasRole[role][account] = true;
        emit RoleGranted(role, account, msg.sender);
    }

    function revokeRole(bytes32 role, address account) external onlyAdmin {
        if (!_hasRole[role][account]) revert NotGranted();
        _hasRole[role][account] = false;
        emit RoleRevoked(role, account, msg.sender);
    }
}
