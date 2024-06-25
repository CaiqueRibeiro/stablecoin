// SPDX-License-Identifier: MIT

// @title An interface to define DSC engine methods to be implemented
// @notice A contract that act as an engine must implement this interface
pragma solidity 0.8.24;

interface IDSCEngine {
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external;

    function redeemCollateralForDsc() external;

    function redeemCollateral() external;

    function burnDsc() external;

    function liquidate() external;

    function getHealthFactor() external view;
}
