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
    address auditor = address(0xA0D);
    address outsider = address(0xBAD);

    uint256 aId;
    bytes32 engine;

    function _part(string memory pn, string memory sn, string memory mfr)
        internal
        pure
        returns (PartRegistry.PartInput memory)
    {
        return PartRegistry.PartInput({
            partNumber: pn,
            serialNumber: sn,
            manufacturer: mfr,
            releaseCertHash: keccak256(abi.encode("Form 1", sn)), // stand-in certificate hash
            hourLimit: 0,
            cycleLimit: 0,
            hoursSinceNew: 0,
            cyclesSinceNew: 0
        });
    }

    function setUp() public {
        vm.startPrank(admin);
        roles = new RoleManager(admin);
        roles.grantRole(roles.MRO_ROLE(), mro);
        roles.grantRole(roles.ENGINEER_ROLE(), engineer);
        roles.grantRole(roles.AUDITOR_ROLE(), auditor);
        vm.stopPrank();

        aircraft = new AircraftRegistry(roles);
        parts = new PartRegistry(roles, aircraft);
        mlog = new MaintenanceLog(roles, aircraft, parts);

        vm.startPrank(mro);
        aId = aircraft.registerAircraft("5Y-ABC", "B737-800", "Kenya Airways");
        engine = parts.registerPart(_part("CFM56-7B", "SN-ENG-0001", "CFM International"));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- RoleManager

    function testGrantRole_RevertsIfAlreadyGranted() public {
        bytes32 mroRole = roles.MRO_ROLE();
        vm.prank(admin);
        vm.expectRevert(RoleManager.AlreadyGranted.selector);
        roles.grantRole(mroRole, mro);
    }

    function testGrantRole_RevertsForInvalidRole() public {
        vm.prank(admin);
        vm.expectRevert(RoleManager.InvalidRole.selector);
        roles.grantRole(keccak256("PILOT_ROLE"), outsider);
    }

    function testGrantRole_RevertsForNonAdmin() public {
        bytes32 mroRole = roles.MRO_ROLE();
        vm.prank(mro);
        vm.expectRevert(RoleManager.NotAdmin.selector);
        roles.grantRole(mroRole, outsider);
    }

    function testRevokeRole_RemovesAccess() public {
        bytes32 mroRole = roles.MRO_ROLE();
        vm.prank(admin);
        roles.revokeRole(mroRole, mro);
        assertFalse(roles.hasRole(mroRole, mro));

        vm.prank(mro);
        vm.expectRevert(AircraftRegistry.NotAuthorized.selector);
        aircraft.registerAircraft("5Y-XYZ", "A320", "Jambojet");
    }

    function testRevokeRole_CannotRemoveLastAdmin() public {
        bytes32 adminRole = roles.ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(RoleManager.LastAdmin.selector);
        roles.revokeRole(adminRole, admin);
    }

    function testRevokeRole_AdminCanStepDownWhenAnotherAdminExists() public {
        bytes32 adminRole = roles.ADMIN_ROLE();
        address admin2 = address(0xA22);
        vm.startPrank(admin);
        roles.grantRole(adminRole, admin2);
        assertEq(roles.adminCount(), 2);
        roles.revokeRole(adminRole, admin);
        vm.stopPrank();

        assertEq(roles.adminCount(), 1);
        assertFalse(roles.hasRole(adminRole, admin));
        assertTrue(roles.hasRole(adminRole, admin2));
    }

    function testRoleGranted_EmitsEvent() public {
        bytes32 engRole = roles.ENGINEER_ROLE();
        vm.expectEmit(true, true, true, true, address(roles));
        emit RoleManager.RoleGranted(engRole, outsider, admin);
        vm.prank(admin);
        roles.grantRole(engRole, outsider);
    }

    // ---------------------------------------------------------------- AircraftRegistry

    function testRegisterAircraft_AdminOrMRO() public {
        vm.prank(admin);
        uint256 id2 = aircraft.registerAircraft("5Y-DEF", "A320", "Jambojet");
        assertEq(id2, 2);
        assertTrue(aircraft.exists(id2));
    }

    function testRegisterAircraft_RevertsForOutsider() public {
        vm.prank(outsider);
        vm.expectRevert(AircraftRegistry.NotAuthorized.selector);
        aircraft.registerAircraft("5Y-ZZZ", "B787", "Some Airline");
    }

    function testRegisterAircraft_RevertsOnDuplicate() public {
        vm.prank(mro);
        vm.expectRevert(AircraftRegistry.AircraftExists.selector);
        aircraft.registerAircraft("5Y-ABC", "B737-800", "Kenya Airways");
    }

    function testRegisterAircraft_RevertsOnEmptyField() public {
        vm.prank(mro);
        vm.expectRevert(AircraftRegistry.EmptyString.selector);
        aircraft.registerAircraft("", "B737-800", "Kenya Airways");
    }

    // ---------------------------------------------------------------- PartRegistry

    function testRegisterPart_SameSerialDifferentManufacturerIsAllowed() public {
        vm.prank(mro);
        bytes32 other = parts.registerPart(_part("CFM56-7B", "SN-ENG-0001", "Another OEM"));
        assertTrue(other != engine);
        assertTrue(parts.partExists(other));
    }

    function testRegisterPart_RevertsOnDuplicate() public {
        vm.prank(mro);
        vm.expectRevert(PartRegistry.PartExists.selector);
        parts.registerPart(_part("CFM56-7B", "SN-ENG-0001", "CFM International"));
    }

    function testRegisterPart_RevertsForEngineer() public {
        vm.prank(engineer);
        vm.expectRevert(PartRegistry.NotAuthorized.selector);
        parts.registerPart(_part("PN-1", "SN-1", "OEM"));
    }

    function testPartKey_MatchesReturnedId() public view {
        assertEq(parts.partKey("CFM International", "CFM56-7B", "SN-ENG-0001"), engine);
    }

    function testPartLifecycle_RegisterInstallRemoveReinstall() public {
        vm.startPrank(mro);
        parts.installPart(aId, engine);
        assertTrue(parts.isInstalledOn(engine, aId));

        parts.removePart(aId, engine);
        PartRegistry.Part memory p = parts.getPart(engine);
        assertEq(uint256(p.status), uint256(PartRegistry.PartStatus.REMOVED));
        assertEq(p.installedAircraftId, 0);

        // A removed (serviceable) part may be reinstalled.
        parts.installPart(aId, engine);
        vm.stopPrank();
        assertTrue(parts.isInstalledOn(engine, aId));
    }

    function testInstallPart_RevertsIfAircraftMissing() public {
        vm.prank(mro);
        vm.expectRevert(PartRegistry.AircraftNotFound.selector);
        parts.installPart(999, engine);
    }

    function testInstallPart_RevertsIfAlreadyInstalled() public {
        vm.startPrank(mro);
        uint256 a2 = aircraft.registerAircraft("5Y-DEF", "A320", "Jambojet");
        parts.installPart(aId, engine);
        vm.expectRevert(PartRegistry.AlreadyInstalled.selector);
        parts.installPart(a2, engine);
        vm.stopPrank();
    }

    function testInstallPart_RevertsIfScrapped() public {
        vm.startPrank(mro);
        parts.scrapPart(engine);
        vm.expectRevert(PartRegistry.PartIsScrapped.selector);
        parts.installPart(aId, engine);
        vm.stopPrank();
    }

    function testRemovePart_RevertsIfWrongAircraft() public {
        vm.startPrank(mro);
        uint256 a2 = aircraft.registerAircraft("5Y-DEF", "A320", "Jambojet");
        parts.installPart(aId, engine);
        vm.expectRevert(PartRegistry.NotInstalledOnThatAircraft.selector);
        parts.removePart(a2, engine);
        vm.stopPrank();
    }

    function testScrapPart_RevertsIfInstalled() public {
        vm.startPrank(mro);
        parts.installPart(aId, engine);
        vm.expectRevert(PartRegistry.MustRemoveBeforeScrap.selector);
        parts.scrapPart(engine);
        vm.stopPrank();
    }

    function testScrapPart_AfterRemovalEmitsBothEvents() public {
        vm.startPrank(mro);
        parts.installPart(aId, engine);

        vm.expectEmit(true, true, true, true, address(parts));
        emit PartRegistry.PartRemoved(engine, aId, mro);
        parts.removePart(aId, engine);

        vm.expectEmit(true, true, true, true, address(parts));
        emit PartRegistry.PartScrapped(engine, mro);
        parts.scrapPart(engine);
        vm.stopPrank();

        assertEq(uint256(parts.statusOf(engine)), uint256(PartRegistry.PartStatus.SCRAPPED));
    }

    function testScrapPart_RevertsIfAlreadyScrapped() public {
        vm.startPrank(mro);
        parts.scrapPart(engine);
        vm.expectRevert(PartRegistry.PartIsScrapped.selector);
        parts.scrapPart(engine);
        vm.stopPrank();
    }

    function testStatusOf_RevertsForUnknownPart() public {
        vm.expectRevert(PartRegistry.PartNotFound.selector);
        parts.statusOf(bytes32(uint256(123)));
    }

    // ---------------------------------------------------------------- MaintenanceLog

    // SHA-256 literals: a sha256() call is a precompile call and would consume vm.prank.
    bytes32 constant DOC = 0x1a7d233e33e1a97979566f1b77904f31f14169ae84308ed3825bbbf45267a100; // sha256("work card v1")
    bytes32 constant DOC2 = 0x66e231dbd1cce4eadc4f55f7bd146279ee7d07bb0c15301c7a4988c4b83dee58; // sha256("work card v2")

    function _rec(uint256 aircraftId, bytes32 partId, string memory action)
        internal
        pure
        returns (MaintenanceLog.Record memory)
    {
        return MaintenanceLog.Record({
            aircraftId: aircraftId,
            partId: partId,
            action: action,
            docHash: DOC,
            docUri: "ipfs://QmWorkCard",
            requiresInspection: false
        });
    }

    function _install() internal {
        vm.prank(mro);
        parts.installPart(aId, engine);
    }

    function testLogMaintenance_EngineerCanLogOnInstalledPart() public {
        _install();
        vm.prank(engineer);
        uint256 logId = mlog.logMaintenance(_rec(aId, engine, "Engine borescope inspection"));

        assertEq(logId, 0);
        assertEq(mlog.count(), 1);
        MaintenanceLog.MaintenanceEvent memory e = mlog.get(logId);
        assertEq(e.engineer, engineer);
        assertEq(e.submitter, engineer);
        assertEq(e.partId, engine);
        assertEq(e.docHash, DOC);
        assertFalse(e.isAmendment);
    }

    function testLogMaintenance_RevertsIfPartNotOnThatAircraft() public {
        vm.prank(mro);
        uint256 a2 = aircraft.registerAircraft("5Y-DEF", "A320", "Jambojet");
        _install(); // installed on aId, not a2

        vm.prank(engineer);
        vm.expectRevert(MaintenanceLog.PartNotOnAircraft.selector);
        mlog.logMaintenance(_rec(a2, engine, "Inspection"));
    }

    function testLogMaintenance_RevertsIfPartNotInstalledAnywhere() public {
        vm.prank(engineer);
        vm.expectRevert(MaintenanceLog.PartNotOnAircraft.selector);
        mlog.logMaintenance(_rec(aId, engine, "Inspection"));
    }

    function testLogMaintenance_ShopWorkOnRemovedPart() public {
        _install();
        vm.prank(mro);
        parts.removePart(aId, engine);

        vm.prank(engineer);
        uint256 logId = mlog.logMaintenance(_rec(0, engine, "Shop overhaul"));
        assertEq(mlog.get(logId).aircraftId, 0);
    }

    function testLogMaintenance_ShopWorkRevertsIfInstalled() public {
        _install();
        vm.prank(engineer);
        vm.expectRevert(MaintenanceLog.PartNotAvailableForShopWork.selector);
        mlog.logMaintenance(_rec(0, engine, "Shop overhaul"));
    }

    function testLogMaintenance_ShopWorkRevertsIfScrapped() public {
        vm.prank(mro);
        parts.scrapPart(engine);
        vm.prank(engineer);
        vm.expectRevert(MaintenanceLog.PartNotAvailableForShopWork.selector);
        mlog.logMaintenance(_rec(0, engine, "Shop overhaul"));
    }

    function testLogMaintenance_RevertsIfOutsider() public {
        _install();
        vm.prank(outsider);
        vm.expectRevert(MaintenanceLog.NotAuthorized.selector);
        mlog.logMaintenance(_rec(aId, engine, "Inspection"));
    }

    function testLogMaintenance_RevertsIfAuditor() public {
        _install();
        vm.prank(auditor);
        vm.expectRevert(MaintenanceLog.NotAuthorized.selector);
        mlog.logMaintenance(_rec(aId, engine, "Inspection"));
    }

    function testLogMaintenance_RevertsOnEmptyDocHash() public {
        _install();
        vm.prank(engineer);
        MaintenanceLog.Record memory r = _rec(aId, engine, "Inspection");
        r.docHash = bytes32(0);
        vm.expectRevert(MaintenanceLog.EmptyDocHash.selector);
        mlog.logMaintenance(r);
    }

    function testLogMaintenance_EmitsEvent() public {
        _install();
        vm.expectEmit(true, true, true, true, address(mlog));
        emit MaintenanceLog.MaintenanceLogged(
            0, aId, engine, "Inspection", DOC, "ipfs://QmWorkCard", engineer, engineer
        );
        vm.prank(engineer);
        mlog.logMaintenance(_rec(aId, engine, "Inspection"));
    }

    function testAmendMaintenance_KeepsOriginalAndLinks() public {
        _install();
        vm.startPrank(engineer);
        uint256 original = mlog.logMaintenance(_rec(aId, engine, "Torque check 50 Nm"));
        uint256 fix = mlog.amendMaintenance(original, "Torque check 55 Nm (corrected)", DOC2, "ipfs://QmV2");
        vm.stopPrank();

        assertEq(mlog.count(), 2);
        assertEq(mlog.get(original).action, "Torque check 50 Nm"); // unchanged
        MaintenanceLog.MaintenanceEvent memory a = mlog.get(fix);
        assertTrue(a.isAmendment);
        assertEq(a.amendsLogId, original);
        assertEq(a.partId, engine);
        assertEq(mlog.amendmentsOf(original).length, 1);
        assertEq(mlog.amendmentsOf(original)[0], fix);
    }

    function testAmendMaintenance_RevertsForUnknownLog() public {
        vm.prank(engineer);
        vm.expectRevert(MaintenanceLog.LogNotFound.selector);
        mlog.amendMaintenance(42, "x", DOC, "");
    }

    function testFlagRecord_AuditorOnly() public {
        _install();
        vm.prank(engineer);
        uint256 logId = mlog.logMaintenance(_rec(aId, engine, "Inspection"));

        vm.prank(engineer);
        vm.expectRevert(MaintenanceLog.NotAuthorized.selector);
        mlog.flagRecord(logId, "self-flag");

        vm.expectEmit(true, true, false, true, address(mlog));
        emit MaintenanceLog.RecordFlagged(logId, auditor, "Doc hash does not match work card");
        vm.prank(auditor);
        mlog.flagRecord(logId, "Doc hash does not match work card");
        assertTrue(mlog.flagged(logId));

        vm.prank(auditor);
        vm.expectRevert(MaintenanceLog.AlreadyFlagged.selector);
        mlog.flagRecord(logId, "again");
    }

    function testGet_RevertsForUnknownLog() public {
        vm.expectRevert(MaintenanceLog.LogNotFound.selector);
        mlog.get(0);
    }

    // ---------------------------------------------------------------- Fuzz

    function testFuzz_OutsiderCannotWrite(address who) public {
        vm.assume(who != admin && who != mro && who != engineer);
        _install();

        vm.startPrank(who);
        vm.expectRevert(AircraftRegistry.NotAuthorized.selector);
        aircraft.registerAircraft("5Y-FZZ", "B737", "Op");
        vm.expectRevert(PartRegistry.NotAuthorized.selector);
        parts.registerPart(_part("PN", "SN", "OEM"));
        vm.expectRevert(MaintenanceLog.NotAuthorized.selector);
        mlog.logMaintenance(_rec(aId, engine, "x"));
        vm.stopPrank();
    }

    function testFuzz_PartIdsAreDistinctAcrossFields(string memory a, string memory b) public view {
        vm.assume(keccak256(bytes(a)) != keccak256(bytes(b)));
        assertTrue(parts.partKey(a, "PN", "SN") != parts.partKey(b, "PN", "SN"));
        assertTrue(parts.partKey("OEM", a, "SN") != parts.partKey("OEM", b, "SN"));
        // Moving characters between fields must not collide (abi.encode, not encodePacked).
        assertTrue(parts.partKey("AB", "C", "SN") != parts.partKey("A", "BC", "SN"));
    }
}
