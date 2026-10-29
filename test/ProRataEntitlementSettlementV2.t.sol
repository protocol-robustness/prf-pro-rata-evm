// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ProRataEntitlementSettlementV2} from "../src/ProRataEntitlementSettlementV2.sol";
import {IProRataSettlementToken} from "../src/IProRataSettlementToken.sol";
import {IProRataProofModeSource} from "../src/IProRataProofModeSource.sol";

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
            bytes32 private constant CHAIN_INSTANCE = keccak256("fixture-chain-instance");
            bytes32 private constant OP = keccak256("operation");
            bytes32 private constant BINDING = keccak256("allocation-binding");
            bytes32 private constant POLICY = keccak256("policy-profile-v2");
            bytes32 private constant IDENTITY = keccak256("claim-identity");
            bytes32 private constant SALT = keccak256("opening-salt");
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
                    new ProRataEntitlementSettlementV2(address(this), CHAIN_INSTANCE, source);
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
                    new ProRataEntitlementSettlementV2(address(this), CHAIN_INSTANCE, source);
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
                settlement = new ProRataEntitlementSettlementV2(address(this), CHAIN_INSTANCE, source);
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
                bytes32 leaf = keccak256(
                    abi.encode(
                        keccak256("prf.pro-rata-entitlement.deployment-scoped.v2"),
                        keccak256("prf.pro-rata-entitlement.table-leaf.v2"),
                        chainId,
                        CHAIN_INSTANCE,
                        allocator,
                        token,
                        OP,
                        BINDING,
                        uint256(0),
                        IDENTITY,
                        BENEFICIARY,
                        uint256(10),
                        POLICY,
                        floor,
                        SALT
                    )
                );
                return
                    keccak256(
                        abi.encode(keccak256("prf.pro-rata-entitlement.table-root.v2"), leaf, uint256(1), uint256(10))
                    );
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
                        CHAIN_INSTANCE,
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
