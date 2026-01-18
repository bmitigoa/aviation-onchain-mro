// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/RoleManager.sol";
import "../src/AircraftRegistry.sol";
import "../src/PartRegistry.sol";
import "../src/MaintenanceLog.sol";

contract AviationMROTest is Test {
    RoleManager roles;
    AircraftRegistry aircraft;
    PartRegistry parts;
    MaintenanceLog mlog;

    address admin = address(0xA11CE);
    address mro = address(0xB0B);
    address engineer = address(0xE11);
    address outsider = address(0xBAD);

    function setUp() public {
    // Deploy RoleManager AS admin (msg.sender = admin)
    vm.startPrank(admin);
    roles = new RoleManager(admin);

    // Now these work because msg.sender is admin
    roles.grantRole(roles.MRO_ROLE(), mro);
    roles.grantRole(roles.ENGINEER_ROLE(), engineer);
    vm.stopPrank();

    aircraft = new AircraftRegistry(roles);
    parts = new PartRegistry(roles, aircraft);
    mlog = new MaintenanceLog(roles, aircraft, parts);
    }

    function testRegisterAircraft_AdminOrMRO() public {
        vm.prank(mro);
        uint256 id = aircraft.registerAircraft("5Y-ABC", "B737-800", "Kenya Airways");
        assertEq(id, 1);

        vm.prank(admin);
        uint256 id2 = aircraft.registerAircraft("5Y-DEF", "A320", "Jambojet");
        assertEq(id2, 2);
    }

    function testRegisterAircraft_RevertsForOutsider() public {
        vm.prank(outsider);
        vm.expectRevert(AircraftRegistry.NotAuthorized.selector);
        aircraft.registerAircraft("5Y-ZZZ", "B787", "Some Airline");
    }

    function testPartLifecycle_RegisterInstallRemove() public {
        vm.prank(mro);
        uint256 aId = aircraft.registerAircraft("5Y-ABC", "B737-800", "Kenya Airways");

        vm.prank(mro);
        parts.registerPart("GE-CFM56", "SN-ENG-0001", "GE Aviation");

        vm.prank(mro);
        parts.installPart(aId, "SN-ENG-0001");

        PartRegistry.Part memory p = parts.getPart("SN-ENG-0001");
        assertEq(uint256(p.status), uint256(PartRegistry.PartStatus.INSTALLED));
        assertEq(p.installedAircraftId, aId);

        vm.prank(mro);
        parts.removePart(aId, "SN-ENG-0001");

        p = parts.getPart("SN-ENG-0001");
        assertEq(uint256(p.status), uint256(PartRegistry.PartStatus.REMOVED));
        assertEq(p.installedAircraftId, 0);
    }

    function testInstallPart_RevertsIfAircraftMissing() public {
        vm.prank(mro);
        parts.registerPart("GE-CFM56", "SN-ENG-0001", "GE Aviation");

        vm.prank(mro);
        vm.expectRevert(PartRegistry.AircraftNotFound.selector);
        parts.installPart(999, "SN-ENG-0001");
    }

    function testLogMaintenance_EngineerCanLog() public {
        vm.prank(mro);
        uint256 aId = aircraft.registerAircraft("5Y-ABC", "B737-800", "Kenya Airways");

        vm.prank(mro);
        parts.registerPart("GE-CFM56", "SN-ENG-0001", "GE Aviation");

        vm.prank(engineer);
        uint256 logId = mlog.logMaintenance(
            aId,
            "SN-ENG-0001",
            "Engine inspection (A-check)",
            "QmFakeIpfsCidOrPdfHash123"
        );

        assertEq(logId, 0);
        assertEq(mlog.count(), 1);
    }

    function testLogMaintenance_RevertsIfOutsider() public {
        vm.prank(mro);
        uint256 aId = aircraft.registerAircraft("5Y-ABC", "B737-800", "Kenya Airways");

        vm.prank(mro);
        parts.registerPart("GE-CFM56", "SN-ENG-0001", "GE Aviation");

        vm.prank(outsider);
        vm.expectRevert(MaintenanceLog.NotAuthorized.selector);
        mlog.logMaintenance(aId, "SN-ENG-0001", "Inspection", "hash");
    }
}
