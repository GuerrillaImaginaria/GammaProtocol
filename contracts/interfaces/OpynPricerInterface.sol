// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.6.12;

interface OpynPricerInterface {
    function getPrice() external view returns (uint256);
}
