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

    function redeemCollateralForDsc(address collateralTokenAddress, uint256 amountCollateral, uint256 amountDscToBurn) external;

    function liquidate(address collateral, address user, uint256 debtToCover) external;

    function getHealthFactor() external view;
}
