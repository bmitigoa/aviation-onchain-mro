// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "../src/RoleManager.sol";
import "../src/AircraftRegistry.sol";
import "../src/PartRegistry.sol";
import "../src/MaintenanceLog.sol";
import "../src/BatchAnchor.sol";

/// @dev Minimal ERC-1271 smart-contract wallet controlled by one EOA (e.g. an MRO's multisig stand-in).
contract SimpleWallet is IERC1271 {
    address public immutable owner;

    constructor(address o) {
        owner = o;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address rec,,) = ECDSA.tryRecover(hash, sig);
        return rec == owner ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

contract CryptographyTest is Test {
    RoleManager roles;
    AircraftRegistry aircraft;
    PartRegistry parts;
    MaintenanceLog mlog;
    BatchAnchor anchor;

    address admin = address(0xA11CE);
    address mro = address(0xB0B); // acts as relayer
    address engineer;
    uint256 engineerKey;
    address outsider;
    uint256 outsiderKey;

    uint256 aId;
    bytes32 engine;

    // SHA-256 literal: a sha256() call is a precompile call and would consume vm.prank.
    bytes32 constant DOC = 0xf23ceea3300d23218052e2da152617c5f75ff5227c4d1b4c61c18e2b3de79aa9; // sha256("Borescope report 5Y-ABC ESN-0001")

    function setUp() public {
        (engineer, engineerKey) = makeAddrAndKey("engineer");
        (outsider, outsiderKey) = makeAddrAndKey("outsider");

        vm.startPrank(admin);
        roles = new RoleManager(admin);
        roles.grantRole(roles.MRO_ROLE(), mro);
        roles.grantRole(roles.ENGINEER_ROLE(), engineer);
        vm.stopPrank();

        aircraft = new AircraftRegistry(roles);
        parts = new PartRegistry(roles, aircraft);
        mlog = new MaintenanceLog(roles, aircraft, parts);
        anchor = new BatchAnchor(roles, aircraft);

        vm.startPrank(mro);
        aId = aircraft.registerAircraft("5Y-ABC", "B737-800", "Kenya Airways");
        engine = parts.registerPart("CFM56-7B", "SN-ENG-0001", "CFM International");
        parts.installPart(aId, engine);
        vm.stopPrank();
    }

    function _rec() internal view returns (MaintenanceLog.Record memory) {
        return MaintenanceLog.Record({
            aircraftId: aId, partId: engine, action: "HPT borescope inspection", docHash: DOC, docUri: "ipfs://QmReport"
        });
    }

    function _sign(uint256 key, MaintenanceLog.Record memory r, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(key, mlog.recordDigest(r, nonce, deadline));
        return abi.encodePacked(rr, s, v);
    }

    // ---------------------------------------------------------------- EIP-712

    function testDigest_MatchesEIP712Spec() public view {
        MaintenanceLog.Record memory r = _rec();
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AviationMRO MaintenanceLog"),
                keccak256("1"),
                block.chainid,
                address(mlog)
            )
        );
        assertEq(mlog.domainSeparator(), domain);

        bytes32 structHash = keccak256(
            abi.encode(
                mlog.MAINTENANCE_RECORD_TYPEHASH(),
                r.aircraftId,
                r.partId,
                keccak256(bytes(r.action)),
                r.docHash,
                keccak256(bytes(r.docUri)),
                uint256(0),
                uint256(1000)
            )
        );
        assertEq(mlog.recordDigest(r, 0, 1000), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    function testBySig_RelayerSubmitsEngineerSignedRecord() public {
        MaintenanceLog.Record memory r = _rec();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(engineerKey, r, 0, deadline);

        vm.prank(mro);
        uint256 logId = mlog.logMaintenanceBySig(r, engineer, deadline, sig);

        MaintenanceLog.MaintenanceEvent memory e = mlog.get(logId);
        assertEq(e.engineer, engineer, "accountable signer");
        assertEq(e.submitter, mro, "relayer");
        assertEq(e.docHash, DOC);
        assertEq(mlog.nonces(engineer), 1);
    }

    function testBySig_AnyoneCanRelay() public {
        MaintenanceLog.Record memory r = _rec();
        bytes memory sig = _sign(engineerKey, r, 0, block.timestamp + 1);
        vm.prank(address(0xDEAD)); // no role needed to relay; authority comes from the signature
        uint256 logId = mlog.logMaintenanceBySig(r, engineer, block.timestamp + 1, sig);
        assertEq(mlog.get(logId).engineer, engineer);
    }

    function testBySig_ReplayReverts() public {
        MaintenanceLog.Record memory r = _rec();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(engineerKey, r, 0, deadline);

        mlog.logMaintenanceBySig(r, engineer, deadline, sig);
        vm.expectRevert(MaintenanceLog.InvalidSignature.selector);
        mlog.logMaintenanceBySig(r, engineer, deadline, sig);
    }

    function testBySig_ExpiredReverts() public {
        MaintenanceLog.Record memory r = _rec();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(engineerKey, r, 0, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(MaintenanceLog.SignatureExpired.selector);
        mlog.logMaintenanceBySig(r, engineer, deadline, sig);
    }

    function testBySig_TamperedRecordReverts() public {
        MaintenanceLog.Record memory r = _rec();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(engineerKey, r, 0, deadline);

        r.docHash = bytes32(uint256(DOC) ^ 1);
        vm.expectRevert(MaintenanceLog.InvalidSignature.selector);
        mlog.logMaintenanceBySig(r, engineer, deadline, sig);
    }

    function testBySig_ClaimingSomeoneElsesSignatureReverts() public {
        MaintenanceLog.Record memory r = _rec();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(outsiderKey, r, 0, deadline);

        vm.expectRevert(MaintenanceLog.InvalidSignature.selector);
        mlog.logMaintenanceBySig(r, engineer, deadline, sig);
    }

    function testBySig_SignerWithoutRoleReverts() public {
        MaintenanceLog.Record memory r = _rec();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(outsiderKey, r, 0, deadline);

        vm.expectRevert(MaintenanceLog.NotAuthorized.selector);
        mlog.logMaintenanceBySig(r, outsider, deadline, sig);
    }

    function testBySig_RevokedEngineerCannotUseOldSignature() public {
        MaintenanceLog.Record memory r = _rec();
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _sign(engineerKey, r, 0, deadline);

        bytes32 engRole = roles.ENGINEER_ROLE();
        vm.prank(admin);
        roles.revokeRole(engRole, engineer);

        vm.expectRevert(MaintenanceLog.NotAuthorized.selector);
        mlog.logMaintenanceBySig(r, engineer, deadline, sig);
    }

    function testBySig_ERC1271ContractWallet() public {
        SimpleWallet wallet = new SimpleWallet(engineer);
        bytes32 engRole = roles.ENGINEER_ROLE();
        vm.prank(admin);
        roles.grantRole(engRole, address(wallet));

        MaintenanceLog.Record memory r = _rec();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(engineerKey, r, 0, deadline);

        uint256 logId = mlog.logMaintenanceBySig(r, address(wallet), deadline, sig);
        assertEq(mlog.get(logId).engineer, address(wallet));
    }

    function testFuzz_BySig_OnlyTheRealKeyWorks(uint256 key) public {
        key = bound(key, 1, 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140);
        vm.assume(key != engineerKey);

        MaintenanceLog.Record memory r = _rec();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(key, r, 0, deadline);

        vm.expectRevert(MaintenanceLog.InvalidSignature.selector);
        mlog.logMaintenanceBySig(r, engineer, deadline, sig);
    }

    // ---------------------------------------------------------------- Document verification

    function testVerifyDocument() public {
        vm.prank(engineer);
        uint256 logId = mlog.logMaintenance(_rec());

        bytes32 original = sha256("Borescope report 5Y-ABC ESN-0001");
        bytes32 edited = sha256("Borescope report 5Y-ABC ESN-0001 (edited)");
        assertTrue(mlog.verifyDocument(logId, original));
        assertFalse(mlog.verifyDocument(logId, edited));
    }

    function testVerifyDocument_UnknownLogReverts() public {
        vm.expectRevert(MaintenanceLog.LogNotFound.selector);
        mlog.verifyDocument(7, DOC);
    }

    // ---------------------------------------------------------------- Merkle batches

    /// Root and proofs come from tools/build-batch.mjs (OpenZeppelin merkle-tree JS library),
    /// proving the off-chain tool and the contract agree.
    function testBatch_VerifiesEveryItemFromOffChainTree() public {
        string memory json = vm.readFile("tools/examples/c-check-package.tree.json");
        bytes32 root = vm.parseJsonBytes32(json, ".root");
        uint256 n = vm.parseJsonUint(json, ".leafCount");

        vm.prank(mro);
        uint256 batchId = anchor.anchorBatch(aId, root, uint32(n), "ipfs://QmCCheckPackage");

        for (uint256 i; i < n; i++) {
            string memory k = string.concat(".items[", vm.toString(i), "]");
            bytes32 partId = vm.parseJsonBytes32(json, string.concat(k, ".partId"));
            string memory taskRef = vm.parseJsonString(json, string.concat(k, ".taskRef"));
            bytes32 docHash = vm.parseJsonBytes32(json, string.concat(k, ".docHash"));
            bytes32[] memory proof = vm.parseJsonBytes32Array(json, string.concat(k, ".proof"));

            assertTrue(anchor.verifyItem(batchId, partId, taskRef, docHash, proof), taskRef);
            // Altering any field breaks the proof.
            assertFalse(anchor.verifyItem(batchId, partId, string.concat(taskRef, " "), docHash, proof));
            assertFalse(anchor.verifyItem(batchId, partId, taskRef, bytes32(uint256(docHash) ^ 1), proof));
        }

        // The example engine part ID is the on-chain partKey of the registered engine.
        assertEq(vm.parseJsonBytes32(json, ".items[0].partId"), engine);
    }

    function testBatch_OnlyAdminOrMRO() public {
        vm.prank(engineer);
        vm.expectRevert(BatchAnchor.NotAuthorized.selector);
        anchor.anchorBatch(aId, bytes32(uint256(1)), 1, "");
    }

    function testBatch_RejectsEmptyRootOrCount() public {
        vm.startPrank(mro);
        vm.expectRevert(BatchAnchor.EmptyRoot.selector);
        anchor.anchorBatch(aId, bytes32(0), 1, "");
        vm.expectRevert(BatchAnchor.EmptyBatch.selector);
        anchor.anchorBatch(aId, bytes32(uint256(1)), 0, "");
        vm.stopPrank();
    }

    function testBatch_RejectsUnknownAircraft() public {
        vm.prank(mro);
        vm.expectRevert(BatchAnchor.AircraftNotFound.selector);
        anchor.anchorBatch(99, bytes32(uint256(1)), 1, "");
    }

    function testBatch_ShopPackageWithoutAircraft() public {
        vm.prank(mro);
        uint256 id = anchor.anchorBatch(0, bytes32(uint256(1)), 3, "ipfs://QmShop");
        BatchAnchor.Batch memory b = anchor.get(id);
        assertEq(b.aircraftId, 0);
        assertEq(b.anchoredBy, mro);
        assertEq(anchor.count(), 1);
    }

    function testBatch_UnknownBatchReverts() public {
        vm.expectRevert(BatchAnchor.BatchNotFound.selector);
        anchor.verifyItem(0, engine, "x", DOC, new bytes32[](0));
    }
}
