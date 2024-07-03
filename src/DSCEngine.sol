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
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10%

    // address of permited collateral tokens (same as key of "s_priceFeeds")
    address[] private s_collateralTokens;
    // price feed for each collateral token
    mapping(address token => address priceFeed) private s_priceFeeds;
    // how much user deposited for each collateral
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    // amount of stablecoin minted for each user
    mapping(address user => uint256 dscMintedAmount) private s_DSCMinted;

    DecentralizedStableCoin private immutable i_dscToken;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);

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

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    function redeemCollateralForDsc(address collateralTokenAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
        override
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(collateralTokenAddress, amountCollateral);
    }

    // If we start nearing undercollateralization we need someone to liquidate positions
    // If someone is amost undercollateralized we'll pay you to liquidate them
    function liquidate(address collateral, address user, uint256 debtToCover) external override {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeeem);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view override {}

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
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

    function redeemCollateral(address tokenCollateralAddress, uint256 amount)
        public
        moreThanZero(amount)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dscToken.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amountDsc) public {
        _burnDsc(amountDsc, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    // Sums the collateral value (in USD) of each collateral token user deposited.
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

    // Get USD value of the token using Chainlink Data Feed
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // ex: 1 ETH = $1000
        // The returned value from CL will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _redeemCollateral( address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dscToken.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dscToken.burn(amountDscToBurn);
    }

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
}
