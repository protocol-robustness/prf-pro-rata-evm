# prf-pro-rata-evm

Independent Solidity implementation of a narrow pro-rata entitlement settlement capability.

## Current status

This repository is a local implementation candidate. It is not released, deployed, or qualified. The new deployment-scoped claim profile is not yet adopted by `prf-pro-rata-allocation`; its commitment roots are candidate vectors pending cross-language review and matching canonical vectors from that owner.

The implementation is written independently. It does not import `prf-evm` contracts or implementation code.

## Ownership boundary

- `prf-pro-rata-allocation` owns normative allocation semantics and shared Clojure/Rust conformance vectors.
- `prf-pro-rata-evm` owns this Solidity settlement implementation and its EVM-specific verification tests.
- `prf-evm` may integrate through a narrow adapter. This repository must not depend on `prf-evm`.
- Source authentication, reserve policy, verifier admission, governance implementation and deployment qualification remain outside this repository.

The entitlement table proves membership in a committed table; it does not prove the allocation is fair or that the underlying claim population is complete. Those claims require the allocation validator or an admitted proof from their owning systems.

## Candidate behavior

`ProRataEntitlementSettlementV2` is non-upgradeable and currently provides:

- operation creation with an immutable minimum proof mode;
- exact-token funding and pre-activation refund;
- activation and liability accounting;
- one-time, deployment-scoped entitlement withdrawal;
- exact sender/recipient token-delta checks and retry after transfer failure;
- a live governed proof mode and caller minimum that may strengthen, but cannot weaken, the operation's stored minimum.

The candidate leaf binds the profile version, `block.chainid`, the PRF `chain-instance-genesis.v1` root, `address(this)`, token address, operation and allocation roots, entitlement index and identity, beneficiary, amount, policy profile, and immutable minimum proof mode. The table opening additionally binds its salt. The genesis root is an opaque constructor input; this contract does not authenticate it. The integrating deployment/evidence profile must independently derive it and verify it against the sealed genesis contract.

The initial implementation has no proxy support, reserve, proof registry, or governance engine. Withdrawals remain publicly observable: beneficiary, amount, calldata opening and timing are not private.

## Candidate vector

The `testCandidateGoldenRootsMatchIndependentCastEncoding` fixture uses fixed inputs and compares table and allocation roots against values computed independently with Foundry `cast abi-encode` and `cast keccak`. These are regression vectors for this candidate implementation, **not adopted canonical vectors**. Adoption requires the allocation/canonical owners to reproduce and approve the same values in their implementation languages.

## Checks

```sh
forge fmt --check
forge test
```

The current tests cover substitution of the chain-instance root, chain ID, allocator, asset, operation, allocation binding, entitlement index and identity, beneficiary, amount, policy, proof floor and profile domain. They also reject a legacy source-bound V2 claim root, exercise a three-leaf odd-width Merkle proof (including rejection of an incorrect duplicate-last sibling), test the pre-activation Required-to-Requested downgrade case, exact-transfer rollback and retry, and pre-activation refund. These are candidate implementation tests; they do not authenticate the constructor-supplied genesis root or qualify a deployment.
