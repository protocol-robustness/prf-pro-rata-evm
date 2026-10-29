// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

interface IProRataSettlementToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}
