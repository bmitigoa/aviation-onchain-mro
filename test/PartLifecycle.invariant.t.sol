// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/RoleManager.sol";
import "../src/AircraftRegistry.sol";
import "../src/PartRegistry.sol";

/// @dev Drives random sequences of lifecycle calls. Reverts are expected and ignored;
///      the handler records which parts were ever scrapped.
contract PartHandler is Test {
    PartRegistry public parts;
    uint256 public constant AIRCRAFT = 3;
    bytes32[] public partIds;
    mapping(bytes32 => bool) public everScrapped;

    constructor(PartRegistry p, bytes32[] memory ids) {
        parts = p;
        partIds = ids;
    }

    function _pid(uint256 seed) internal view returns (bytes32) {
        return partIds[seed % partIds.length];
    }

    function install(uint256 pSeed, uint256 aSeed) external {
        try parts.installPart((aSeed % AIRCRAFT) + 1, _pid(pSeed)) {} catch {}
    }

    function remove(uint256 pSeed, uint256 aSeed) external {
        try parts.removePart((aSeed % AIRCRAFT) + 1, _pid(pSeed)) {} catch {}
    }

    function scrap(uint256 pSeed) external {
        bytes32 id = _pid(pSeed);
        try parts.scrapPart(id) {
            everScrapped[id] = true;
        } catch {}
    }

    function count() external view returns (uint256) {
        return partIds.length;
    }
}

contract PartLifecycleInvariantTest is Test {
    PartRegistry parts;
    PartHandler handler;

    function setUp() public {
        RoleManager roles = new RoleManager(address(this));
        AircraftRegistry aircraft = new AircraftRegistry(roles);
        parts = new PartRegistry(roles, aircraft);

        aircraft.registerAircraft("5Y-AAA", "B737", "Op");
        aircraft.registerAircraft("5Y-BBB", "A320", "Op");
        aircraft.registerAircraft("5Y-CCC", "E190", "Op");

        bytes32[] memory ids = new bytes32[](4);
        ids[0] = parts.registerPart("PN-1", "SN-1", "OEM");
        ids[1] = parts.registerPart("PN-1", "SN-2", "OEM");
        ids[2] = parts.registerPart("PN-2", "SN-1", "OEM");
        ids[3] = parts.registerPart("PN-3", "SN-9", "OEM-B");

        handler = new PartHandler(parts, ids);
        roles.grantRole(roles.MRO_ROLE(), address(handler));
        targetContract(address(handler));
    }

    /// Once scrapped, a part stays scrapped and is never on an aircraft.
    function invariant_ScrappedIsTerminal() public view {
        for (uint256 i; i < handler.count(); i++) {
            bytes32 id = handler.partIds(i);
            if (handler.everScrapped(id)) {
                PartRegistry.Part memory p = parts.getPart(id);
                assertEq(uint256(p.status), uint256(PartRegistry.PartStatus.SCRAPPED));
                assertEq(p.installedAircraftId, 0);
            }
        }
    }

    /// installedAircraftId is set if and only if the part is INSTALLED.
    function invariant_InstalledAircraftMatchesStatus() public view {
        for (uint256 i; i < handler.count(); i++) {
            PartRegistry.Part memory p = parts.getPart(handler.partIds(i));
            if (p.status == PartRegistry.PartStatus.INSTALLED) {
                assertGt(p.installedAircraftId, 0);
            } else {
                assertEq(p.installedAircraftId, 0);
            }
        }
    }
}
