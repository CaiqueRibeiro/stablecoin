// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IDSCEngine} from "./interfaces/IDSCEngine.sol";
import {NoDelegateCall} from "./NoDelegateCall.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is IDSCEngine, NoDelegateCall, ReentrancyGuard {
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSC_Engine__InvalidDecentralizedToken();
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSEngine__MintFailed();

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dscMintedAmount) private s_DSCMinted;
    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dscToken;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);

    modifier moreThanZero(uint256 amountCollateral) {
        if (amountCollateral == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier onlyAllowedToken(address collateralTokenAddress) {
        if (s_priceFeeds[collateralTokenAddress] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddressess, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddressess.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        if (dscAddress == address(0)) {
            revert DSC_Engine__InvalidDecentralizedToken();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddressess[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dscToken = DecentralizedStableCoin(dscAddress);
    }

    function depositCollateralAndMintDsc(uint256 amountDscToMint) external {}

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        override
        onlyAllowedToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc() external override {}

    function redeemCollateral() external override {}

    function mintDsc(uint256 amountDscToMint) external override moreThanZero(amountDscToMint) {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dscToken.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSEngine__MintFailed();
        }
    }

    function burnDsc() external override {}

    function liquidate() external override {}

    function getHealthFactor() external view override {}

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
        Returns how close to liquidation the user is
        If a user goes below 1, then they can be liquidated
    */
    function _healthFactor(address user) private view returns (uint256) {
        // totalDscMinted: total DSC minted
        // collateralValueInUsd: total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        /*
            Using liquidation threshold means with have two have double (200%) minted DSC than the collateral value
            1000 ETH * 50 = 50,000 / 100 = 500
            $150 ETH / 100 DSC = 1.5
            150 * 50 = 7500 / 100 = $75 ETH = ($75 ETH / 100 DSC < 1)
        */
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    // 1. Check health factor (do they have enough collateral?)
    // 2. Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollaterlValueInUsed) {
        /*  loop through each collateral token, get the amount they've deposited,
            and map it to the price, to get the USD value
        */
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollaterlValueInUsed += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // The returned value from CL will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
