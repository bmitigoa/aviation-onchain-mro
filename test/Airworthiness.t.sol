// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/RoleManager.sol";
import "../src/AircraftRegistry.sol";
import "../src/PartRegistry.sol";
import "../src/MaintenanceLog.sol";

/// @notice Release certificates, life-limited parts and Required Inspection Items.
contract AirworthinessTest is Test {
    RoleManager roles;
    AircraftRegistry aircraft;
    PartRegistry parts;
    MaintenanceLog mlog;

    address admin = address(0xA11CE);
    address mro = address(0xB0B);
    address engineer = address(0xE11);
    address engineer2 = address(0xE22);
    address inspector = address(0x1D5);
    address outsider = address(0xBAD);

    // SHA-256 literals: a sha256() call is a precompile call and would consume vm.prank.
    bytes32 constant FORM1 = 0x3c13e0ba2b5a31b2e7a6f0d3b2bc2e3c5f4f0b8a3f6d6e2f0a1b2c3d4e5f6a7b; // sample Form 1
    bytes32 constant FORM1_AFTER_OVERHAUL = 0x9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b;
    bytes32 constant DOC = 0x1a7d233e33e1a97979566f1b77904f31f14169ae84308ed3825bbbf45267a100;

    uint256 aId;
    bytes32 disk; // life-limited: 1,000 h / 400 cycles

    function setUp() public {
        vm.startPrank(admin);
        roles = new RoleManager(admin);
        roles.grantRole(roles.MRO_ROLE(), mro);
        roles.grantRole(roles.ENGINEER_ROLE(), engineer);
        roles.grantRole(roles.ENGINEER_ROLE(), engineer2);
        roles.grantRole(roles.INSPECTOR_ROLE(), inspector);
        vm.stopPrank();

        aircraft = new AircraftRegistry(roles);
        parts = new PartRegistry(roles, aircraft);
        mlog = new MaintenanceLog(roles, aircraft, parts);

        vm.startPrank(mro);
        aId = aircraft.registerAircraft("5Y-ABC", "B737-800", "Kenya Airways");
        disk = parts.registerPart(_llp(1000, 400, 0, 0));
        vm.stopPrank();
    }

    function _llp(uint32 hourLimit, uint32 cycleLimit, uint32 hsn, uint32 csn)
        internal
        pure
        returns (PartRegistry.PartInput memory)
    {
        return PartRegistry.PartInput({
            partNumber: "HPT-DISK-1",
            serialNumber: "SN-DSK-0042",
            manufacturer: "CFM International",
            releaseCertHash: FORM1,
            hourLimit: hourLimit,
            cycleLimit: cycleLimit,
            hoursSinceNew: hsn,
            cyclesSinceNew: csn
        });
    }

    function _one(bytes32 id) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = id;
    }

    // ================================================================ Release certificates

    function testRegister_RequiresReleaseCertificate() public {
        PartRegistry.PartInput memory p = _llp(0, 0, 0, 0);
        p.serialNumber = "SN-NOCERT";
        p.releaseCertHash = bytes32(0);
        vm.prank(mro);
        vm.expectRevert(PartRegistry.EmptyCertificate.selector);
        parts.registerPart(p);
    }

    function testVerifyReleaseCertificate() public view {
        assertTrue(parts.verifyReleaseCertificate(disk, FORM1));
        assertFalse(parts.verifyReleaseCertificate(disk, FORM1_AFTER_OVERHAUL));
    }

    function testRegister_EmitsCertificateAndLimitEvents() public {
        PartRegistry.PartInput memory p = _llp(500, 100, 0, 0);
        p.serialNumber = "SN-NEW";
        bytes32 id = parts.partKey(p.manufacturer, p.partNumber, p.serialNumber);

        vm.expectEmit(true, true, true, true, address(parts));
        emit PartRegistry.ReleaseCertificateRecorded(id, FORM1, mro);
        vm.expectEmit(true, false, false, true, address(parts));
        emit PartRegistry.LifeLimitsSet(id, 500, 100);
        vm.prank(mro);
        parts.registerPart(p);
    }

    function testRecordReleaseCertificate_AfterShopVisit() public {
        vm.startPrank(mro);
        parts.installPart(aId, disk);
        parts.removePart(aId, disk);

        vm.expectEmit(true, true, true, true, address(parts));
        emit PartRegistry.ReleaseCertificateRecorded(disk, FORM1_AFTER_OVERHAUL, mro);
        parts.recordReleaseCertificate(disk, FORM1_AFTER_OVERHAUL);
        vm.stopPrank();

        assertTrue(parts.verifyReleaseCertificate(disk, FORM1_AFTER_OVERHAUL));
        assertFalse(parts.verifyReleaseCertificate(disk, FORM1));
    }

    function testRecordReleaseCertificate_RevertsWhileInstalled() public {
        vm.startPrank(mro);
        parts.installPart(aId, disk);
        vm.expectRevert(PartRegistry.CertificateWhileInstalled.selector);
        parts.recordReleaseCertificate(disk, FORM1_AFTER_OVERHAUL);
        vm.stopPrank();
    }

    function testRecordReleaseCertificate_RevertsIfScrappedOrEmptyOrOutsider() public {
        vm.prank(outsider);
        vm.expectRevert(PartRegistry.NotAuthorized.selector);
        parts.recordReleaseCertificate(disk, FORM1_AFTER_OVERHAUL);

        vm.startPrank(mro);
        vm.expectRevert(PartRegistry.EmptyCertificate.selector);
        parts.recordReleaseCertificate(disk, bytes32(0));

        parts.scrapPart(disk);
        vm.expectRevert(PartRegistry.PartIsScrapped.selector);
        parts.recordReleaseCertificate(disk, FORM1_AFTER_OVERHAUL);
        vm.stopPrank();
    }

    // ================================================================ Life-limited parts

    function testUsage_AccruesAndRemainingLife() public {
        vm.startPrank(mro);
        parts.installPart(aId, disk);
        parts.recordUsage(_one(disk), 6, 4);
        parts.recordUsage(_one(disk), 10, 2);
        vm.stopPrank();

        PartRegistry.Part memory p = parts.getPart(disk);
        assertEq(p.hoursSinceNew, 16);
        assertEq(p.cyclesSinceNew, 6);
        (uint32 h, uint32 c) = parts.remainingLife(disk);
        assertEq(h, 984);
        assertEq(c, 394);
    }

    function testUsage_UnlimitedPartReportsMax() public {
        PartRegistry.PartInput memory p = _llp(0, 0, 0, 0);
        p.serialNumber = "SN-UNLIMITED";
        vm.prank(mro);
        bytes32 id = parts.registerPart(p);
        (uint32 h, uint32 c) = parts.remainingLife(id);
        assertEq(h, type(uint32).max);
        assertEq(c, type(uint32).max);
        assertFalse(parts.isLifeExpired(id));
    }

    function testUsage_OnlyForInstalledParts() public {
        vm.prank(mro);
        vm.expectRevert(PartRegistry.NotInstalled.selector);
        parts.recordUsage(_one(disk), 1, 1);
    }

    function testUsage_OnlyAdminOrMRO() public {
        vm.prank(mro);
        parts.installPart(aId, disk);
        vm.prank(engineer);
        vm.expectRevert(PartRegistry.NotAuthorized.selector);
        parts.recordUsage(_one(disk), 1, 1);
    }

    function testUsage_BatchAppliesToEveryPart() public {
        PartRegistry.PartInput memory p = _llp(0, 0, 100, 50);
        p.serialNumber = "SN-OTHER";
        vm.startPrank(mro);
        bytes32 other = parts.registerPart(p);
        parts.installPart(aId, disk);
        parts.installPart(aId, other);

        bytes32[] memory both = new bytes32[](2);
        both[0] = disk;
        both[1] = other;
        parts.recordUsage(both, 5, 3);
        vm.stopPrank();

        assertEq(parts.getPart(disk).cyclesSinceNew, 3);
        assertEq(parts.getPart(other).cyclesSinceNew, 53);
    }

    function testLifeLimit_ExceededEmitsOnceAndBlocksReinstall() public {
        vm.startPrank(mro);
        parts.installPart(aId, disk);
        parts.recordUsage(_one(disk), 100, 399);
        assertFalse(parts.isLifeExpired(disk));

        vm.expectEmit(true, false, false, true, address(parts));
        emit PartRegistry.LifeLimitExceeded(disk, 110, 400);
        parts.recordUsage(_one(disk), 10, 1);
        assertTrue(parts.isLifeExpired(disk));

        // Usage is still recorded truthfully after the limit
        parts.recordUsage(_one(disk), 2, 1);
        assertEq(parts.getPart(disk).cyclesSinceNew, 401);
        (, uint32 c) = parts.remainingLife(disk);
        assertEq(c, 0);

        // Once removed, an expired part cannot go back on
        parts.removePart(aId, disk);
        vm.expectRevert(PartRegistry.LifeLimitReached.selector);
        parts.installPart(aId, disk);

        // ...but it can be scrapped
        parts.scrapPart(disk);
        vm.stopPrank();
    }

    function testLifeLimit_UsedPartRegisteredAtLimitCannotBeInstalled() public {
        PartRegistry.PartInput memory p = _llp(1000, 0, 1000, 0); // hour limit already reached
        p.serialNumber = "SN-TIMEX";
        vm.startPrank(mro);
        bytes32 id = parts.registerPart(p);
        vm.expectRevert(PartRegistry.LifeLimitReached.selector);
        parts.installPart(aId, id);
        vm.stopPrank();
    }

    function testFuzz_LifeLimitNeverExceededAtInstall(uint32 cycleLimit, uint32 csn) public {
        cycleLimit = uint32(bound(cycleLimit, 1, 100_000));
        csn = uint32(bound(csn, 0, 200_000));
        PartRegistry.PartInput memory p = _llp(0, cycleLimit, 0, csn);
        p.serialNumber = "SN-FUZZ";

        vm.startPrank(mro);
        bytes32 id = parts.registerPart(p);
        if (csn >= cycleLimit) vm.expectRevert(PartRegistry.LifeLimitReached.selector);
        parts.installPart(aId, id);
        vm.stopPrank();
    }

    // ================================================================ Required Inspection Items

    function _riiRecord(bool rii) internal view returns (MaintenanceLog.Record memory) {
        return MaintenanceLog.Record({
            aircraftId: aId,
            partId: disk,
            action: "HPT disk installation torque",
            docHash: DOC,
            docUri: "ipfs://QmWorkCard",
            requiresInspection: rii
        });
    }

    function _logRii() internal returns (uint256 logId) {
        vm.prank(mro);
        parts.installPart(aId, disk);
        MaintenanceLog.Record memory r = _riiRecord(true);
        vm.prank(engineer);
        logId = mlog.logMaintenance(r);
    }

    function testRII_NotReleasedUntilInspected() public {
        uint256 logId = _logRii();
        assertFalse(mlog.isReleased(logId));

        vm.expectEmit(true, true, true, true, address(mlog));
        emit MaintenanceLog.InspectionSignedOff(logId, inspector, engineer);
        vm.prank(inspector);
        mlog.signInspection(logId);

        assertTrue(mlog.isReleased(logId));
        MaintenanceLog.MaintenanceEvent memory e = mlog.get(logId);
        assertEq(e.inspector, inspector);
        assertEq(e.inspectedAt, uint64(block.timestamp));
    }

    function testRII_NonRiiRecordIsReleasedImmediately() public {
        vm.prank(mro);
        parts.installPart(aId, disk);
        MaintenanceLog.Record memory r = _riiRecord(false);
        vm.prank(engineer);
        uint256 logId = mlog.logMaintenance(r);
        assertTrue(mlog.isReleased(logId));

        vm.prank(inspector);
        vm.expectRevert(MaintenanceLog.InspectionNotRequired.selector);
        mlog.signInspection(logId);
    }

    function testRII_EngineerCannotInspectOwnWork() public {
        bytes32 inspectorRole = roles.INSPECTOR_ROLE();
        vm.prank(admin);
        roles.grantRole(inspectorRole, engineer); // engineer is ALSO an inspector

        uint256 logId = _logRii();
        vm.prank(engineer);
        vm.expectRevert(MaintenanceLog.CannotInspectOwnWork.selector);
        mlog.signInspection(logId);
    }

    function testRII_OnlyInspectorRole() public {
        uint256 logId = _logRii();
        vm.prank(engineer2); // another engineer, but not an inspector
        vm.expectRevert(MaintenanceLog.NotAuthorized.selector);
        mlog.signInspection(logId);
    }

    function testRII_CannotInspectTwice() public {
        uint256 logId = _logRii();
        vm.prank(inspector);
        mlog.signInspection(logId);
        vm.prank(inspector);
        vm.expectRevert(MaintenanceLog.AlreadyInspected.selector);
        mlog.signInspection(logId);
    }

    function testRII_AmendmentNeedsFreshInspection() public {
        uint256 logId = _logRii();
        vm.prank(inspector);
        mlog.signInspection(logId);

        vm.prank(engineer);
        uint256 fix = mlog.amendMaintenance(logId, "Torque re-done, corrected value", DOC, "ipfs://QmFix");
        assertTrue(mlog.get(fix).requiresInspection);
        assertFalse(mlog.isReleased(fix));

        vm.prank(inspector);
        mlog.signInspection(fix);
        assertTrue(mlog.isReleased(fix));
    }

    function testRII_UnknownLogReverts() public {
        vm.prank(inspector);
        vm.expectRevert(MaintenanceLog.LogNotFound.selector);
        mlog.signInspection(99);
        vm.expectRevert(MaintenanceLog.LogNotFound.selector);
        mlog.isReleased(99);
    }

    function testInspectorRole_CanBeGranted() public view {
        assertTrue(roles.hasRole(roles.INSPECTOR_ROLE(), inspector));
    }
}
