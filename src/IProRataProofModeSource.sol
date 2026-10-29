// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

interface IProRataProofModeSource {
    function currentEntitlementProofMode() external view returns (uint8);
}
