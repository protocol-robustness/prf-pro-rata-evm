// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ProRataEntitlementSettlementV2} from "../src/ProRataEntitlementSettlementV2.sol";
import {IProRataSettlementToken} from "../src/IProRataSettlementToken.sol";
import {IProRataProofModeSource} from "../src/IProRataProofModeSource.sol";

interface Vm {
    function readFile(string calldata path) external view returns (string memory data);
    function parseJsonBytes32(string calldata json, string calldata key) external pure returns (bytes32 value);
}

contract SettlementTestToken is IProRataSettlementToken {
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public feeEnabled;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function setFeeEnabled(bool enabled) external {
        feeEnabled = enabled;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        require(approved >= amount, "allowance");
        allowance[from][msg.sender] = approved - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        if (feeEnabled && amount != 0) {
            balanceOf[to] += amount - 1;
            balanceOf[address(this)] += 1;
        } else {
            balanceOf[to] += amount;
        }
    }
}

    contract SettlementTestModeSource is IProRataProofModeSource {
        uint8 public override currentEntitlementProofMode;

        function setMode(uint8 mode) external {
            currentEntitlementProofMode = mode;
        }
    }

        contract ProRataEntitlementSettlementV2Test {
            Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
            bytes32 private constant CHAIN_INSTANCE_GENESIS_ROOT =
                0x88c4d0ca7ce42120b8059a6a4f894be3a8d8c563e5d228b5fd067932fe2aad73;
            bytes32 private constant OP = keccak256("operation");
            bytes32 private constant BINDING = keccak256("allocation-binding");
            bytes32 private constant POLICY = keccak256("policy-profile-v2");
            bytes32 private constant IDENTITY = keccak256("claim-identity");
            bytes32 private constant SALT = keccak256("opening-salt");
            bytes32 private constant TABLE_NODE_DOMAIN = keccak256("prf.pro-rata-entitlement.table-node.v2");
            bytes32 private constant TABLE_ROOT_DOMAIN = keccak256("prf.pro-rata-entitlement.table-root.v2");
            bytes32 private constant CLAIM_NODE_DOMAIN = keccak256("prf.pro-rata-entitlement.claim-node.v2");
            bytes32 private constant CLAIM_ROOT_DOMAIN = keccak256("prf.pro-rata-entitlement.claim-root.v2");
            address private constant BENEFICIARY = address(0xBEEF);

            function testCandidateGoldenRootsMatchIndependentCastEncoding() external pure {
                require(
                    _tableRoot(address(0x1234), address(0x5678), 31337, 1)
                        == 0x111dd3c7306bd17fbd9c924dde090f235d791bf893091262d483f08677958057,
                    "candidate table root changed"
                );
                require(
                    _claimRoot(address(0x1234), address(0x5678), 31337, 1)
                        == 0x97673b87e79f3ba61da9bb3b9afedcff339552318ff14270b271661f7f2cb6ac,
                    "candidate claim root changed"
                );
            }

            function testCandidateMachineReadableVectorMatchesGoldenRoots() external view {
                string memory vector = VM.readFile("fixtures/deployment-scoped-entitlement-v2.candidate.json");
                require(
                    _tableRoot(address(0x1234), address(0x5678), 31337, 1)
                        == VM.parseJsonBytes32(vector, ".expected.entitlement_table_root"),
                    "fixture table root differs"
                );
                require(
                    _claimRoot(address(0x1234), address(0x5678), 31337, 1)
                        == VM.parseJsonBytes32(vector, ".expected.allocation_claim_root"),
                    "fixture claim root differs"
                );
            }

            function test_ApprovedRequiredFloorSurvivesGovernanceDowngradeBeforeActivation() external {
                (
                    SettlementTestToken token,
                    SettlementTestModeSource source,
                    ProRataEntitlementSettlementV2 settlement
                ) = _createScenario(1, 1, address(0), block.chainid);

                token.mint(address(this), 10);
                token.approve(address(settlement), 10);
                settlement.fund(OP);

                // Governance lowers the live mode while funded but before activation.
                source.setMode(0);
                settlement.activate(OP);

                ProRataEntitlementSettlementV2.Opening memory opening = _opening();
                bytes32[] memory noSiblings = new bytes32[](0);
                (bool missingProofAccepted,) = address(settlement)
                    .call(
                        abi.encodeCall(
                            ProRataEntitlementSettlementV2.withdraw,
                            (
                                OP,
                                opening,
                                noSiblings,
                                false,
                                noSiblings,
                                ProRataEntitlementSettlementV2.ProofMode.Requested
                            )
                        )
                    );
                require(!missingProofAccepted, "immutable Required floor was weakened");
                require(token.balanceOf(BENEFICIARY) == 0, "rejected withdrawal paid");
                require(settlement.operation(OP).outstandingLiability == 10, "rejected withdrawal changed liability");

                bytes32[] memory validAllocationProof = new bytes32[](0);
                settlement.withdraw(
                    OP,
                    opening,
                    noSiblings,
                    true,
                    validAllocationProof,
                    ProRataEntitlementSettlementV2.ProofMode.Requested
                );
                require(token.balanceOf(BENEFICIARY) == 10, "valid proof did not pay exact entitlement");
                require(settlement.operation(OP).status == ProRataEntitlementSettlementV2.Status.Closed, "not closed");
            }

            function test_DeploymentAndChainSubstitutionReject() external {
                _assertSubstitutionRejected(address(0), block.chainid + 1);
                _assertSubstitutionRejected(address(0x1234), block.chainid);
            }

            function test_AssetSubstitutionRejects() external {
                SettlementTestToken token = new SettlementTestToken();
                SettlementTestToken substitutedAsset = new SettlementTestToken();
                SettlementTestModeSource source = new SettlementTestModeSource();
                ProRataEntitlementSettlementV2 settlement =
                    new ProRataEntitlementSettlementV2(address(this), CHAIN_INSTANCE_GENESIS_ROOT, source);
                bytes32 tableRoot = _tableRoot(address(settlement), address(substitutedAsset), block.chainid, 0);
                bytes32 claimRoot = _claimRoot(address(settlement), address(substitutedAsset), block.chainid, 0);
                settlement.createOperation(
                    OP,
                    BINDING,
                    tableRoot,
                    claimRoot,
                    POLICY,
                    token,
                    10,
                    1,
                    ProRataEntitlementSettlementV2.ProofMode.Requested
                );
                token.mint(address(this), 10);
                token.approve(address(settlement), 10);
                settlement.fund(OP);
                settlement.activate(OP);
                bytes32[] memory empty = new bytes32[](0);
                (bool accepted,) = address(settlement)
                    .call(
                        abi.encodeCall(
                            ProRataEntitlementSettlementV2.withdraw,
                            (OP, _opening(), empty, true, empty, ProRataEntitlementSettlementV2.ProofMode.Requested)
                        )
                    );
                require(!accepted, "substituted token identity accepted");
                require(token.balanceOf(BENEFICIARY) == 0, "substitution rejection paid");
                require(settlement.operation(OP).outstandingLiability == 10, "substitution rejection changed liability");
            }

            function test_ChainInstanceOperationAndAllocationBindingSubstitutionReject() external {
                _assertContextSubstitutionRejected(0); // chain-instance genesis root
                _assertContextSubstitutionRejected(1); // operation ID
                _assertContextSubstitutionRejected(2); // allocation binding root
            }

            function test_EntitlementAndPolicySubstitutionReject() external {
                _assertContextSubstitutionRejected(3); // entitlement index
                _assertContextSubstitutionRejected(4); // claim identity
                _assertContextSubstitutionRejected(5); // beneficiary
                _assertContextSubstitutionRejected(6); // amount
                _assertContextSubstitutionRejected(7); // policy profile
            }

            function testProofFloorAndProfileSubstitutionReject() external {
                _assertContextSubstitutionRejected(8); // immutable proof-mode floor
                _assertContextSubstitutionRejected(9); // profile domain
            }

            function testLegacySourceBoundV2ClaimRootCannotAuthorizeCandidateWithdrawal() external {
                SettlementTestToken token = new SettlementTestToken();
                SettlementTestModeSource source = new SettlementTestModeSource();
                ProRataEntitlementSettlementV2 settlement =
                    new ProRataEntitlementSettlementV2(address(this), CHAIN_INSTANCE_GENESIS_ROOT, source);
                bytes32 tableRoot = _tableRoot(address(settlement), address(token), block.chainid, 1);
                bytes32 legacyClaimLeaf = keccak256(
                    abi.encode(
                        keccak256("prf.source-bound-entitlement.claim-leaf.v1"),
                        BINDING,
                        OP,
                        uint256(0),
                        keccak256(
                            abi.encodePacked(bytes1(0x20), bytes1(uint8(bytes("claim-a").length)), bytes("claim-a"))
                        ),
                        BENEFICIARY,
                        uint256(10),
                        keccak256("immutable-address-v1")
                    )
                );
                settlement.createOperation(
                    OP,
                    BINDING,
                    tableRoot,
                    legacyClaimLeaf,
                    POLICY,
                    token,
                    10,
                    1,
                    ProRataEntitlementSettlementV2.ProofMode.Required
                );
                token.mint(address(this), 10);
                token.approve(address(settlement), 10);
                settlement.fund(OP);
                settlement.activate(OP);

                bytes32[] memory empty = new bytes32[](0);
                (bool accepted,) = address(settlement)
                    .call(
                        abi.encodeCall(
                            ProRataEntitlementSettlementV2.withdraw,
                            (OP, _opening(), empty, true, empty, ProRataEntitlementSettlementV2.ProofMode.Requested)
                        )
                    );
                require(!accepted, "legacy V2 claim root authorized candidate withdrawal");
                require(token.balanceOf(BENEFICIARY) == 0, "legacy proof substitution paid");
                require(settlement.operation(OP).outstandingLiability == 10, "legacy proof changed liability");
            }

            function testOddWidthMerkleProofRequiresDuplicateLastSiblingAndPays() external {
                SettlementTestToken token = new SettlementTestToken();
                SettlementTestModeSource source = new SettlementTestModeSource();
                ProRataEntitlementSettlementV2 settlement =
                    new ProRataEntitlementSettlementV2(address(this), CHAIN_INSTANCE_GENESIS_ROOT, source);
                bytes32 operationId = keccak256("odd-width-operation");
                ProRataEntitlementSettlementV2.Opening[] memory openings = new ProRataEntitlementSettlementV2
                    .Opening[](3);
                openings[0] =
                    ProRataEntitlementSettlementV2.Opening(
                    0, keccak256("claim-0"), address(0xA001), 4, keccak256("salt-0")
                );
                openings[1] =
                    ProRataEntitlementSettlementV2.Opening(
                    1, keccak256("claim-1"), address(0xA002), 3, keccak256("salt-1")
                );
                openings[2] =
                    ProRataEntitlementSettlementV2.Opening(
                    2, keccak256("claim-2"), address(0xA003), 3, keccak256("salt-2")
                );

                bytes32[] memory tableLeaves = new bytes32[](3);
                bytes32[] memory claimLeaves = new bytes32[](3);
                for (uint256 i; i < openings.length; ++i) {
                    tableLeaves[i] = _tableLeaf(settlement, token, operationId, BINDING, POLICY, 1, openings[i]);
                    claimLeaves[i] = _claimLeaf(settlement, token, operationId, BINDING, POLICY, 1, openings[i]);
                }
                bytes32 tablePair = _node(TABLE_NODE_DOMAIN, tableLeaves[0], tableLeaves[1]);
                bytes32 tableOdd = _node(TABLE_NODE_DOMAIN, tableLeaves[2], tableLeaves[2]);
                bytes32 tableMembersRoot = _node(TABLE_NODE_DOMAIN, tablePair, tableOdd);
                bytes32 tableRoot = keccak256(abi.encode(TABLE_ROOT_DOMAIN, tableMembersRoot, uint256(3), uint256(10)));
                bytes32 claimPair = _node(CLAIM_NODE_DOMAIN, claimLeaves[0], claimLeaves[1]);
                bytes32 claimOdd = _node(CLAIM_NODE_DOMAIN, claimLeaves[2], claimLeaves[2]);
                bytes32 claimMembersRoot = _node(CLAIM_NODE_DOMAIN, claimPair, claimOdd);
                bytes32 claimRoot = keccak256(abi.encode(CLAIM_ROOT_DOMAIN, claimMembersRoot, uint256(3), uint256(10)));

                settlement.createOperation(
                    operationId,
                    BINDING,
                    tableRoot,
                    claimRoot,
                    POLICY,
                    token,
                    10,
                    3,
                    ProRataEntitlementSettlementV2.ProofMode.Required
                );
                token.mint(address(this), 10);
                token.approve(address(settlement), 10);
                settlement.fund(operationId);
                settlement.activate(operationId);

                bytes32[] memory tableSiblings = new bytes32[](2);
                tableSiblings[0] = tableLeaves[2]; // duplicate the odd-width final leaf
                tableSiblings[1] = tablePair;
                bytes32[] memory claimSiblings = new bytes32[](2);
                claimSiblings[0] = claimLeaves[2];
                claimSiblings[1] = claimPair;

                tableSiblings[0] = tableLeaves[0]; // a non-duplicate sibling must fail closed
                (bool badProofAccepted,) = address(settlement)
                    .call(
                        abi.encodeCall(
                            ProRataEntitlementSettlementV2.withdraw,
                            (
                                operationId,
                                openings[2],
                                tableSiblings,
                                true,
                                claimSiblings,
                                ProRataEntitlementSettlementV2.ProofMode.Requested
                            )
                        )
                    );
                require(!badProofAccepted, "incorrect odd-width duplicate accepted");
                require(token.balanceOf(openings[2].beneficiary) == 0, "invalid odd-width proof paid");
                require(settlement.operation(operationId).outstandingLiability == 10, "invalid proof changed liability");

                tableSiblings[0] = tableLeaves[2];
                settlement.withdraw(
                    operationId,
                    openings[2],
                    tableSiblings,
                    true,
                    claimSiblings,
                    ProRataEntitlementSettlementV2.ProofMode.Requested
                );
                require(token.balanceOf(openings[2].beneficiary) == 3, "valid odd-width proof did not pay");
                require(settlement.operation(operationId).outstandingLiability == 7, "valid proof liability mismatch");
            }

            function test_ExactTransferFailureRollsBackAndAllowsRetry() external {
                (SettlementTestToken token,, ProRataEntitlementSettlementV2 settlement) =
                    _createScenario(0, 0, address(0), block.chainid);
                token.mint(address(this), 10);
                token.approve(address(settlement), 10);
                settlement.fund(OP);
                settlement.activate(OP);
                token.setFeeEnabled(true);
                bytes32[] memory empty = new bytes32[](0);
                (bool paidWithFee,) = address(settlement)
                    .call(
                        abi.encodeCall(
                            ProRataEntitlementSettlementV2.withdraw,
                            (OP, _opening(), empty, false, empty, ProRataEntitlementSettlementV2.ProofMode.Requested)
                        )
                    );
                require(!paidWithFee, "fee-on-transfer accepted");
                require(token.balanceOf(BENEFICIARY) == 0, "failed transfer paid beneficiary");
                require(settlement.operation(OP).outstandingLiability == 10, "failed transfer consumed liability");

                token.setFeeEnabled(false);
                settlement.withdraw(
                    OP, _opening(), empty, false, empty, ProRataEntitlementSettlementV2.ProofMode.Requested
                );
                require(token.balanceOf(BENEFICIARY) == 10, "valid retry did not pay");
            }

            function test_RefundOnlyBeforeActivation() external {
                (SettlementTestToken token,, ProRataEntitlementSettlementV2 settlement) =
                    _createScenario(0, 0, address(0), block.chainid);
                token.mint(address(this), 10);
                token.approve(address(settlement), 10);
                settlement.fund(OP);
                settlement.cancelAndRefund(OP);
                require(token.balanceOf(address(this)) == 10, "refund amount mismatch");
                require(
                    settlement.operation(OP).status == ProRataEntitlementSettlementV2.Status.Cancelled, "not cancelled"
                );
            }

            function _assertSubstitutionRejected(address allocatorForRoot, uint256 chainIdForRoot) private {
                SettlementTestToken token = new SettlementTestToken();
                SettlementTestModeSource source = new SettlementTestModeSource();
                ProRataEntitlementSettlementV2 settlement =
                    new ProRataEntitlementSettlementV2(address(this), CHAIN_INSTANCE_GENESIS_ROOT, source);
                address leafAllocator = allocatorForRoot == address(0) ? address(settlement) : allocatorForRoot;
                bytes32 tableRoot = _tableRoot(leafAllocator, address(token), chainIdForRoot, 0);
                bytes32 claimRoot = _claimRoot(leafAllocator, address(token), chainIdForRoot, 0);
                settlement.createOperation(
                    OP,
                    BINDING,
                    tableRoot,
                    claimRoot,
                    POLICY,
                    token,
                    10,
                    1,
                    ProRataEntitlementSettlementV2.ProofMode.Requested
                );
                token.mint(address(this), 10);
                token.approve(address(settlement), 10);
                settlement.fund(OP);
                settlement.activate(OP);
                bytes32[] memory empty = new bytes32[](0);
                (bool accepted,) = address(settlement)
                    .call(
                        abi.encodeCall(
                            ProRataEntitlementSettlementV2.withdraw,
                            (OP, _opening(), empty, true, empty, ProRataEntitlementSettlementV2.ProofMode.Requested)
                        )
                    );
                require(!accepted, "deployment/chain substituted root accepted");
                require(token.balanceOf(BENEFICIARY) == 0, "substitution rejection paid");
            }

            function _assertContextSubstitutionRejected(uint8 field) private {
                SettlementTestToken token = new SettlementTestToken();
                SettlementTestModeSource source = new SettlementTestModeSource();
                ProRataEntitlementSettlementV2 settlement =
                    new ProRataEntitlementSettlementV2(address(this), CHAIN_INSTANCE_GENESIS_ROOT, source);

                bytes32 genesisRoot = CHAIN_INSTANCE_GENESIS_ROOT;
                address asset = address(token);
                uint256 chainId = block.chainid;
                bytes32 operationId = OP;
                bytes32 bindingRoot = BINDING;
                ProRataEntitlementSettlementV2.Opening memory rootOpening = _opening();
                bytes32 policy = POLICY;
                uint8 proofFloor = 1;
                bytes32 profile = keccak256("prf.pro-rata-entitlement.deployment-scoped.v2");

                if (field == 0) genesisRoot = bytes32(uint256(CHAIN_INSTANCE_GENESIS_ROOT) ^ 1);
                else if (field == 1) operationId = bytes32(uint256(OP) ^ 1);
                else if (field == 2) bindingRoot = bytes32(uint256(BINDING) ^ 1);
                else if (field == 3) rootOpening.index = 1;
                else if (field == 4) rootOpening.claimIdentity = bytes32(uint256(IDENTITY) ^ 1);
                else if (field == 5) rootOpening.beneficiary = address(0x9999);
                else if (field == 6) rootOpening.amount = 9;
                else if (field == 7) policy = bytes32(uint256(POLICY) ^ 1);
                else if (field == 8) proofFloor = 0;
                else if (field == 9) profile = keccak256("prf.source-bound-entitlement.claim-leaf.v1");
                else revert("unknown substitution field");

                bytes32 tableRoot = _candidateTableRoot(
                    profile,
                    address(settlement),
                    asset,
                    chainId,
                    genesisRoot,
                    operationId,
                    bindingRoot,
                    rootOpening,
                    policy,
                    proofFloor
                );
                bytes32 claimRoot = _claimRoot(address(settlement), asset, chainId, 1);
                settlement.createOperation(
                    OP,
                    BINDING,
                    tableRoot,
                    claimRoot,
                    POLICY,
                    token,
                    10,
                    1,
                    ProRataEntitlementSettlementV2.ProofMode.Required
                );
                token.mint(address(this), 10);
                token.approve(address(settlement), 10);
                settlement.fund(OP);
                settlement.activate(OP);

                bytes32[] memory empty = new bytes32[](0);
                (bool accepted,) = address(settlement)
                    .call(
                        abi.encodeCall(
                            ProRataEntitlementSettlementV2.withdraw,
                            (OP, _opening(), empty, true, empty, ProRataEntitlementSettlementV2.ProofMode.Requested)
                        )
                    );
                require(!accepted, "substituted commitment field accepted");
                require(token.balanceOf(BENEFICIARY) == 0, "substitution rejection paid");
                require(settlement.operation(OP).outstandingLiability == 10, "substitution changed liability");
            }

            function _createScenario(uint8 floor, uint8 live, address leafToken, uint256 leafChainId)
                private
                returns (
                    SettlementTestToken token,
                    SettlementTestModeSource source,
                    ProRataEntitlementSettlementV2 settlement
                )
            {
                token = new SettlementTestToken();
                source = new SettlementTestModeSource();
                source.setMode(live);
                settlement = new ProRataEntitlementSettlementV2(address(this), CHAIN_INSTANCE_GENESIS_ROOT, source);
                address tokenIdentity = leafToken == address(0) ? address(token) : leafToken;
                bytes32 tableRoot = _tableRoot(address(settlement), tokenIdentity, leafChainId, floor);
                bytes32 claimRoot = _claimRoot(address(settlement), tokenIdentity, leafChainId, floor);
                settlement.createOperation(
                    OP,
                    BINDING,
                    tableRoot,
                    claimRoot,
                    POLICY,
                    token,
                    10,
                    1,
                    ProRataEntitlementSettlementV2.ProofMode(floor)
                );
            }

            function _opening() private pure returns (ProRataEntitlementSettlementV2.Opening memory) {
                return ProRataEntitlementSettlementV2.Opening(0, IDENTITY, BENEFICIARY, 10, SALT);
            }

            function _tableRoot(address allocator, address token, uint256 chainId, uint8 floor)
                private
                pure
                returns (bytes32)
            {
                return _candidateTableRoot(
                    keccak256("prf.pro-rata-entitlement.deployment-scoped.v2"),
                    allocator,
                    token,
                    chainId,
                    CHAIN_INSTANCE_GENESIS_ROOT,
                    OP,
                    BINDING,
                    _opening(),
                    POLICY,
                    floor
                );
            }

            function _candidateTableRoot(
                bytes32 profile,
                address allocator,
                address token,
                uint256 chainId,
                bytes32 genesisRoot,
                bytes32 operationId,
                bytes32 bindingRoot,
                ProRataEntitlementSettlementV2.Opening memory opening,
                bytes32 policy,
                uint8 floor
            ) private pure returns (bytes32) {
                bytes32 leaf = keccak256(
                    abi.encode(
                        profile,
                        keccak256("prf.pro-rata-entitlement.table-leaf.v2"),
                        chainId,
                        genesisRoot,
                        allocator,
                        token,
                        operationId,
                        bindingRoot,
                        opening.index,
                        opening.claimIdentity,
                        opening.beneficiary,
                        opening.amount,
                        policy,
                        floor,
                        opening.salt
                    )
                );
                return keccak256(abi.encode(TABLE_ROOT_DOMAIN, leaf, uint256(1), uint256(10)));
            }

            function _tableLeaf(
                ProRataEntitlementSettlementV2 settlement,
                SettlementTestToken token,
                bytes32 operationId,
                bytes32 bindingRoot,
                bytes32 policy,
                uint8 proofFloor,
                ProRataEntitlementSettlementV2.Opening memory opening
            ) private view returns (bytes32) {
                return keccak256(
                    abi.encode(
                        keccak256("prf.pro-rata-entitlement.deployment-scoped.v2"),
                        keccak256("prf.pro-rata-entitlement.table-leaf.v2"),
                        block.chainid,
                        CHAIN_INSTANCE_GENESIS_ROOT,
                        address(settlement),
                        address(token),
                        operationId,
                        bindingRoot,
                        opening.index,
                        opening.claimIdentity,
                        opening.beneficiary,
                        opening.amount,
                        policy,
                        proofFloor,
                        opening.salt
                    )
                );
            }

            function _claimLeaf(
                ProRataEntitlementSettlementV2 settlement,
                SettlementTestToken token,
                bytes32 operationId,
                bytes32 bindingRoot,
                bytes32 policy,
                uint8 proofFloor,
                ProRataEntitlementSettlementV2.Opening memory opening
            ) private view returns (bytes32) {
                return keccak256(
                    abi.encode(
                        keccak256("prf.pro-rata-entitlement.deployment-scoped.v2"),
                        keccak256("prf.pro-rata-entitlement.claim-leaf.v2"),
                        block.chainid,
                        CHAIN_INSTANCE_GENESIS_ROOT,
                        address(settlement),
                        address(token),
                        operationId,
                        bindingRoot,
                        opening.index,
                        opening.claimIdentity,
                        opening.beneficiary,
                        opening.amount,
                        policy,
                        proofFloor
                    )
                );
            }

            function _node(bytes32 domain, bytes32 left, bytes32 right) private pure returns (bytes32) {
                return keccak256(abi.encodePacked(domain, left, right));
            }

            function _claimRoot(address allocator, address token, uint256 chainId, uint8 floor)
                private
                pure
                returns (bytes32)
            {
                bytes32 leaf = keccak256(
                    abi.encode(
                        keccak256("prf.pro-rata-entitlement.deployment-scoped.v2"),
                        keccak256("prf.pro-rata-entitlement.claim-leaf.v2"),
                        chainId,
                        CHAIN_INSTANCE_GENESIS_ROOT,
                        allocator,
                        token,
                        OP,
                        BINDING,
                        uint256(0),
                        IDENTITY,
                        BENEFICIARY,
                        uint256(10),
                        POLICY,
                        floor
                    )
                );
                return
                    keccak256(
                        abi.encode(keccak256("prf.pro-rata-entitlement.claim-root.v2"), leaf, uint256(1), uint256(10))
                    );
            }
        }
