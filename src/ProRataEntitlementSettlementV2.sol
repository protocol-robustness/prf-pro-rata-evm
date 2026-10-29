// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IProRataSettlementToken} from "./IProRataSettlementToken.sol";
import {IProRataProofModeSource} from "./IProRataProofModeSource.sol";

/// @notice Independent, non-upgradeable entitlement custody and withdrawal profile.
/// @dev The deployment-scoped commitment layout in this implementation is a candidate
///      pending matching canonical vectors from prf-pro-rata-allocation.
contract ProRataEntitlementSettlementV2 {
    bytes32 public constant PROFILE_ID = keccak256("prf.pro-rata-entitlement.deployment-scoped.v2");
    bytes32 public constant TABLE_LEAF_DOMAIN = keccak256("prf.pro-rata-entitlement.table-leaf.v2");
    bytes32 public constant TABLE_NODE_DOMAIN = keccak256("prf.pro-rata-entitlement.table-node.v2");
    bytes32 public constant TABLE_ROOT_DOMAIN = keccak256("prf.pro-rata-entitlement.table-root.v2");
    bytes32 public constant CLAIM_LEAF_DOMAIN = keccak256("prf.pro-rata-entitlement.claim-leaf.v2");
    bytes32 public constant CLAIM_NODE_DOMAIN = keccak256("prf.pro-rata-entitlement.claim-node.v2");
    bytes32 public constant CLAIM_ROOT_DOMAIN = keccak256("prf.pro-rata-entitlement.claim-root.v2");

    enum Status {
        None,
        Created,
        Funded,
        Activated,
        Claims,
        Closed,
        Cancelled
    }

    enum ProofMode {
        Requested,
        Required
    }

    enum ProofObservation {
        NotProvided,
        Valid,
        Invalid
    }

    struct Operation {
        Status status;
        bytes32 allocationBindingRoot;
        bytes32 entitlementTableRoot;
        bytes32 allocationClaimRoot;
        bytes32 policyProfile;
        IProRataSettlementToken token;
        address fundingSource;
        uint256 amount;
        uint256 entitlementCount;
        uint256 claimedAmount;
        uint256 claimedCount;
        uint256 outstandingLiability;
        ProofMode immutableMinimumProofMode;
    }

    struct Opening {
        uint256 index;
        bytes32 claimIdentity;
        address beneficiary;
        uint256 amount;
        bytes32 salt;
    }

    address public immutable operationAuthority;
    /// @notice PRF chain-instance-genesis.v1 root; its provenance is checked by the deployment adapter.
    bytes32 public immutable chainInstanceGenesisRoot;
    IProRataProofModeSource public immutable proofModeSource;

    mapping(bytes32 operationId => Operation) private _operations;
    mapping(bytes32 operationId => mapping(uint256 word => uint256 bits)) private _consumedWords;
    mapping(bytes32 operationId => mapping(bytes32 identity => bool consumed)) public consumedClaimIdentity;
    bool private _entered;

    error Unauthorized(address caller);
    error InvalidOperation();
    error InvalidState(Status actual);
    error InvalidProofMode(uint8 mode);
    error InvalidProofModeFloor(uint8 mode);
    error InvalidOpening();
    error InvalidEntitlementProof();
    error InvalidAllocationProof();
    error EntitlementAlreadyConsumed(uint256 index);
    error ClaimIdentityAlreadyConsumed(bytes32 identity);
    error ExactTransferRequired();
    error LiabilityExceeded();
    error ReentrantCall();

    event OperationCreated(
        bytes32 indexed operationId,
        bytes32 indexed allocationBindingRoot,
        address indexed token,
        uint256 amount,
        uint256 entitlementCount,
        ProofMode immutableMinimumProofMode
    );
    event OperationFunded(bytes32 indexed operationId, address indexed source, uint256 amount);
    event OperationActivated(bytes32 indexed operationId, uint256 liability);
    event OperationRefunded(bytes32 indexed operationId, address indexed source, uint256 amount);
    event EntitlementWithdrawn(
        bytes32 indexed operationId,
        uint256 indexed index,
        address indexed beneficiary,
        uint256 amount,
        ProofMode effectiveProofMode,
        ProofObservation allocationProofObservation,
        uint256 outstandingLiability
    );
    event OperationClosed(bytes32 indexed operationId, uint256 amount, uint256 count);

    modifier onlyAuthority() {
        if (msg.sender != operationAuthority) revert Unauthorized(msg.sender);
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    constructor(address authority, bytes32 chainInstanceGenesisRoot_, IProRataProofModeSource proofModeSource_) {
        if (
            authority == address(0) || chainInstanceGenesisRoot_ == bytes32(0)
                || address(proofModeSource_) == address(0)
        ) {
            revert InvalidOperation();
        }
        operationAuthority = authority;
        chainInstanceGenesisRoot = chainInstanceGenesisRoot_;
        proofModeSource = proofModeSource_;
    }

    function createOperation(
        bytes32 operationId,
        bytes32 allocationBindingRoot,
        bytes32 entitlementTableRoot,
        bytes32 allocationClaimRoot,
        bytes32 policyProfile,
        IProRataSettlementToken token,
        uint256 amount,
        uint256 entitlementCount,
        ProofMode immutableMinimumProofMode
    ) external onlyAuthority {
        if (
            operationId == bytes32(0) || allocationBindingRoot == bytes32(0) || entitlementTableRoot == bytes32(0)
                || allocationClaimRoot == bytes32(0) || policyProfile == bytes32(0) || address(token) == address(0)
                || amount == 0 || entitlementCount == 0 || uint8(immutableMinimumProofMode) > uint8(ProofMode.Required)
        ) revert InvalidOperation();
        if (_operations[operationId].status != Status.None) revert InvalidState(_operations[operationId].status);
        _operations[operationId] = Operation({
            status: Status.Created,
            allocationBindingRoot: allocationBindingRoot,
            entitlementTableRoot: entitlementTableRoot,
            allocationClaimRoot: allocationClaimRoot,
            policyProfile: policyProfile,
            token: token,
            fundingSource: address(0),
            amount: amount,
            entitlementCount: entitlementCount,
            claimedAmount: 0,
            claimedCount: 0,
            outstandingLiability: 0,
            immutableMinimumProofMode: immutableMinimumProofMode
        });
        emit OperationCreated(
            operationId, allocationBindingRoot, address(token), amount, entitlementCount, immutableMinimumProofMode
        );
    }

    function fund(bytes32 operationId) external onlyAuthority nonReentrant {
        Operation storage op = _operations[operationId];
        if (op.status != Status.Created) revert InvalidState(op.status);
        _transferFromExact(op.token, msg.sender, op.amount);
        op.fundingSource = msg.sender;
        op.status = Status.Funded;
        emit OperationFunded(operationId, msg.sender, op.amount);
    }

    /// @notice Returns funded capital before activation. Activated liabilities are not refundable.
    function cancelAndRefund(bytes32 operationId) external onlyAuthority nonReentrant {
        Operation storage op = _operations[operationId];
        if (op.status != Status.Funded || op.fundingSource == address(0)) revert InvalidState(op.status);
        op.status = Status.Cancelled;
        _transferExact(op.token, op.fundingSource, op.amount);
        emit OperationRefunded(operationId, op.fundingSource, op.amount);
    }

    function activate(bytes32 operationId) external onlyAuthority {
        Operation storage op = _operations[operationId];
        if (op.status != Status.Funded) revert InvalidState(op.status);
        op.outstandingLiability = op.amount;
        op.status = Status.Activated;
        emit OperationActivated(operationId, op.amount);
    }

    function withdraw(
        bytes32 operationId,
        Opening calldata opening,
        bytes32[] calldata tableSiblings,
        bool allocationProofProvided,
        bytes32[] calldata allocationSiblings,
        ProofMode callerMinimum
    ) external nonReentrant {
        Operation storage op = _operations[operationId];
        if (op.status != Status.Activated && op.status != Status.Claims) revert InvalidState(op.status);
        uint8 liveMode = proofModeSource.currentEntitlementProofMode();
        if (liveMode > uint8(ProofMode.Required)) revert InvalidProofMode(liveMode);
        if (uint8(callerMinimum) > uint8(ProofMode.Required)) revert InvalidProofMode(uint8(callerMinimum));
        ProofMode effectiveMode = op.immutableMinimumProofMode;
        if (liveMode > uint8(effectiveMode)) effectiveMode = ProofMode(liveMode);
        if (callerMinimum > effectiveMode) effectiveMode = callerMinimum;

        if (
            opening.index >= op.entitlementCount || opening.claimIdentity == bytes32(0)
                || opening.beneficiary == address(0) || opening.beneficiary == address(this) || opening.amount == 0
        ) revert InvalidOpening();
        uint256 word = opening.index >> 8;
        uint256 bit = uint256(1) << (opening.index & 255);
        if ((_consumedWords[operationId][word] & bit) != 0) revert EntitlementAlreadyConsumed(opening.index);
        if (consumedClaimIdentity[operationId][opening.claimIdentity]) {
            revert ClaimIdentityAlreadyConsumed(opening.claimIdentity);
        }

        bytes32 tableLeaf = entitlementLeaf(operationId, op, opening);
        (bool tableValid, bytes32 tableMembersRoot) =
            _orderedPathRoot(tableLeaf, opening.index, op.entitlementCount, tableSiblings, TABLE_NODE_DOMAIN);
        if (
            !tableValid
                || _rootEnvelope(TABLE_ROOT_DOMAIN, tableMembersRoot, op.entitlementCount, op.amount)
                    != op.entitlementTableRoot
        ) {
            revert InvalidEntitlementProof();
        }

        bool allocationProofValid;
        if (allocationProofProvided) {
            bytes32 claimLeaf = allocationLeaf(operationId, op, opening);
            (bool claimPathValid, bytes32 claimMembersRoot) =
                _orderedPathRoot(claimLeaf, opening.index, op.entitlementCount, allocationSiblings, CLAIM_NODE_DOMAIN);
            allocationProofValid = claimPathValid
                && _rootEnvelope(CLAIM_ROOT_DOMAIN, claimMembersRoot, op.entitlementCount, op.amount)
                    == op.allocationClaimRoot;
        }
        if (effectiveMode == ProofMode.Required && !allocationProofValid) revert InvalidAllocationProof();

        ProofObservation observation = !allocationProofProvided
            ? ProofObservation.NotProvided
            : (allocationProofValid ? ProofObservation.Valid : ProofObservation.Invalid);
        uint256 nextAmount = op.claimedAmount + opening.amount;
        uint256 nextCount = op.claimedCount + 1;
        if (nextAmount > op.amount || nextCount > op.entitlementCount || opening.amount > op.outstandingLiability) {
            revert LiabilityExceeded();
        }

        _consumedWords[operationId][word] |= bit;
        consumedClaimIdentity[operationId][opening.claimIdentity] = true;
        op.claimedAmount = nextAmount;
        op.claimedCount = nextCount;
        op.outstandingLiability -= opening.amount;
        op.status = Status.Claims;
        _transferExact(op.token, opening.beneficiary, opening.amount);

        emit EntitlementWithdrawn(
            operationId,
            opening.index,
            opening.beneficiary,
            opening.amount,
            effectiveMode,
            observation,
            op.outstandingLiability
        );
        if (nextAmount == op.amount && nextCount == op.entitlementCount) {
            if (op.outstandingLiability != 0) revert LiabilityExceeded();
            op.status = Status.Closed;
            emit OperationClosed(operationId, nextAmount, nextCount);
        }
    }

    function operation(bytes32 operationId) external view returns (Operation memory) {
        return _operations[operationId];
    }

    function consumed(bytes32 operationId, uint256 index) external view returns (bool) {
        return (_consumedWords[operationId][index >> 8] & (uint256(1) << (index & 255))) != 0;
    }

    /// @notice Candidate profile v2 table leaf. The contract address and chain domain
    ///         are included, so operation data must be prepared after deployment.
    function entitlementLeaf(bytes32 operationId, Operation storage op, Opening calldata opening)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                PROFILE_ID,
                TABLE_LEAF_DOMAIN,
                block.chainid,
                chainInstanceGenesisRoot,
                address(this),
                address(op.token),
                operationId,
                op.allocationBindingRoot,
                opening.index,
                opening.claimIdentity,
                opening.beneficiary,
                opening.amount,
                op.policyProfile,
                op.immutableMinimumProofMode,
                opening.salt
            )
        );
    }

    function allocationLeaf(bytes32 operationId, Operation storage op, Opening calldata opening)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                PROFILE_ID,
                CLAIM_LEAF_DOMAIN,
                block.chainid,
                chainInstanceGenesisRoot,
                address(this),
                address(op.token),
                operationId,
                op.allocationBindingRoot,
                opening.index,
                opening.claimIdentity,
                opening.beneficiary,
                opening.amount,
                op.policyProfile,
                op.immutableMinimumProofMode
            )
        );
    }

    function _transferFromExact(IProRataSettlementToken token, address from, uint256 amount) private {
        uint256 fromBefore = token.balanceOf(from);
        uint256 custodyBefore = token.balanceOf(address(this));
        if (!token.transferFrom(from, address(this), amount)) revert ExactTransferRequired();
        if (
            fromBefore < token.balanceOf(from) || fromBefore - token.balanceOf(from) != amount
                || token.balanceOf(address(this)) < custodyBefore
                || token.balanceOf(address(this)) - custodyBefore != amount
        ) revert ExactTransferRequired();
    }

    function _transferExact(IProRataSettlementToken token, address to, uint256 amount) private {
        uint256 custodyBefore = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(to);
        if (!token.transfer(to, amount)) revert ExactTransferRequired();
        if (
            custodyBefore < token.balanceOf(address(this)) || custodyBefore - token.balanceOf(address(this)) != amount
                || token.balanceOf(to) < recipientBefore || token.balanceOf(to) - recipientBefore != amount
        ) revert ExactTransferRequired();
    }

    function _rootEnvelope(bytes32 domain, bytes32 membersRoot, uint256 count, uint256 amount)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(domain, membersRoot, count, amount));
    }

    function _orderedPathRoot(
        bytes32 leaf,
        uint256 index,
        uint256 count,
        bytes32[] calldata siblings,
        bytes32 nodeDomain
    ) private pure returns (bool valid, bytes32 root) {
        if (count == 0 || index >= count) return (false, bytes32(0));
        uint256 depth;
        for (uint256 depthWidth = count; depthWidth > 1; depthWidth = (depthWidth + 1) / 2) {
            ++depth;
        }
        if (siblings.length != depth) return (false, bytes32(0));
        root = leaf;
        uint256 width = count;
        uint256 cursor;
        while (width > 1) {
            bytes32 sibling = siblings[cursor++];
            if ((index & 1) == 0) {
                if (index + 1 >= width && sibling != root) return (false, bytes32(0));
                root = keccak256(abi.encodePacked(nodeDomain, root, sibling));
            } else {
                root = keccak256(abi.encodePacked(nodeDomain, sibling, root));
            }
            index >>= 1;
            width = (width + 1) / 2;
        }
        return (true, root);
    }
}
