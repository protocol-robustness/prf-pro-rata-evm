// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/// @notice Minimal read-only boundary to the PRF sealed chain-instance genesis.
/// @dev PRF derives and admits the canonical SHA-256 root off-chain. Consumers
///      must independently obtain the expected root from that admitted process;
///      this interface only reads and checks the sealed on-chain binding.
interface IPrfChainInstanceGenesis {
    function chainInstanceGenesisRoot() external view returns (bytes32);
    function executionChainId() external view returns (uint256);
    function genesisRuntimeCodeHash() external view returns (bytes32);
    function isSealedState() external view returns (bool);
}
