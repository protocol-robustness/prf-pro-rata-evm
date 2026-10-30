# Changelog

## Unreleased — candidate implementation

- Added an independent, non-upgradeable EVM entitlement-settlement candidate with deployment-scoped claim commitments, an immutable per-operation proof-mode floor, exact-transfer custody, pre-activation refunds, single-use withdrawals and liability closure. The candidate profile and vectors are explicitly unadopted pending cross-language review by the canonical allocation owner.
- Added shared three-member odd-width candidate vectors across Clojure, Rust and Solidity, including duplicate-last node and proof-sibling checks. This extends regression coverage without adopting or changing the candidate commitment profile.
- Changed the unadopted candidate constructor to require a sealed PRF genesis anchor and an independently derived expected root; it rejects unsealed, mismatched-root, wrong-chain and runtime-mismatched anchors, then uses the root read back from that anchor for commitment verification.
