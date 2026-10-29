# Deployment-scoped entitlement V2 — candidate encoding

**Status:** candidate for review; not an adopted canonical profile.

This document records the encoding implemented by the initial Solidity candidate. The normative allocation/canonical owner must independently reproduce the vectors and approve the schema before another implementation treats these roots as authoritative. Existing V2 roots and encodings are unaffected.

## Domain constants

All domains below are `keccak256(UTF-8(domain-string))`:

- `PROFILE_ID`: `prf.pro-rata-entitlement.deployment-scoped.v2`
- `TABLE_LEAF_DOMAIN`: `prf.pro-rata-entitlement.table-leaf.v2`
- `TABLE_NODE_DOMAIN`: `prf.pro-rata-entitlement.table-node.v2`
- `TABLE_ROOT_DOMAIN`: `prf.pro-rata-entitlement.table-root.v2`
- `CLAIM_LEAF_DOMAIN`: `prf.pro-rata-entitlement.claim-leaf.v2`
- `CLAIM_NODE_DOMAIN`: `prf.pro-rata-entitlement.claim-node.v2`
- `CLAIM_ROOT_DOMAIN`: `prf.pro-rata-entitlement.claim-root.v2`

## Entitlement table leaf

The preimage is Solidity standard ABI encoding (`abi.encode`, not packed encoding) of the following typed tuple, in order:

1. `bytes32 PROFILE_ID`
2. `bytes32 TABLE_LEAF_DOMAIN`
3. `uint256 block.chainid`
4. `bytes32 chainInstanceGenesisRoot` (the PRF `chain-instance-genesis.v1` SHA-256 root)
5. `address allocator`
6. `address asset`
7. `bytes32 operationId`
8. `bytes32 allocationBindingRoot`
9. `uint256 entitlementIndex`
10. `bytes32 claimIdentity`
11. `address beneficiary`
12. `uint256 amountBaseUnits`
13. `bytes32 policyProfile`
14. `uint8 immutableMinimumProofMode` (`0 = Requested`, `1 = Required`)
15. `bytes32 openingSalt`

The leaf is `keccak256(abi.encode(tuple))`.

## Allocation-claim leaf

The allocation proof leaf uses the same tuple and field types, with `CLAIM_LEAF_DOMAIN` in position 2 and **omits** `openingSalt`. It is also hashed with `keccak256(abi.encode(tuple))`.

## Ordered tree and root envelope

Each tree is an ordered binary Merkle tree. A node is:

`keccak256(abi.encodePacked(nodeDomain, left, right))`

At an odd-width level, the final node is paired with itself; a proof must provide that same node as its sibling. Proof depth is derived from the declared member count and must match exactly. The index determines left/right order.

The final table root is:

`keccak256(abi.encode(TABLE_ROOT_DOMAIN, tableMembersRoot, entitlementCount, totalAmountBaseUnits))`

The final allocation claim root is:

`keccak256(abi.encode(CLAIM_ROOT_DOMAIN, claimMembersRoot, entitlementCount, totalAmountBaseUnits))`

For a single leaf, its members root is the leaf itself.

## Deployment and authority limits

The operation roots can be prepared only after the non-upgradeable allocator address is known, because the allocator address is in each leaf. The contract binds `block.chainid` and the supplied canonical `chainInstanceGenesisRoot`. That root commits to PRF's canonical chain-instance genesis fields, but remains an opaque constructor input here: contract execution alone does not authenticate it. A deployment integration must independently derive it and verify it against the sealed genesis contract before deployment or operation preparation.

`immutableMinimumProofMode` is set by the configured operation authority at operation creation. The contract enforces it as a floor alongside current governed mode and the caller's requested minimum. This contract does not itself prove that the authority's input was approved; that approval belongs to the integrating authority/evidence profile.

## Candidate vector

`fixtures/deployment-scoped-entitlement-v2.candidate.json` records one fixed one-member candidate vector. Its roots were calculated independently with Foundry `cast abi-encode` and `cast keccak`, then asserted in the Foundry suite. It is not a frozen canonical vector until accepted by the semantic owner and reproduced by the relevant Clojure/Rust implementations.
