//SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Account} from "@synthetixio/main/contracts/storage/Account.sol";
import {AccountRBAC} from "@synthetixio/main/contracts/storage/AccountRBAC.sol";
import {ErrorUtil} from "../utils/ErrorUtil.sol";
import {IMarginModule} from "../interfaces/IMarginModule.sol";
import {IERC20} from "@synthetixio/core-contracts/contracts/interfaces/IERC20.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {Order} from "../storage/Order.sol";
import {OwnableStorage} from "@synthetixio/core-contracts/contracts/ownership/OwnableStorage.sol";
import {PerpMarket} from "../storage/PerpMarket.sol";
import {PerpMarketConfiguration} from "../storage/PerpMarketConfiguration.sol";
import {Position} from "../storage/Position.sol";
import {SafeCastI256, SafeCastU256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {Margin} from "../storage/Margin.sol";

contract MarginModule is IMarginModule {
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using PerpMarket for PerpMarket.Data;
    using Position for Position.Data;

    /**
     * @dev Validates whether the margin requirements are acceptable after withdrawing.
     */
    function validatePositionPostWithdraw(
        uint128 accountId,
        Position.Data storage position,
        PerpMarket.Data storage market
    ) private view {
        uint256 oraclePrice = market.getOraclePrice();
        uint256 marginUsd = Margin.getMarginUsd(accountId, market, oraclePrice);

        PerpMarketConfiguration.Data storage marketConfig = PerpMarketConfiguration.load(market.id);

        // Ensure does not lead to instant liquidation.
        if (position.isLiquidatable(market, marginUsd, oraclePrice, marketConfig)) {
            revert ErrorUtil.CanLiquidatePosition();
        }

        (uint256 im, , ) = Position.getLiquidationMarginUsd(position.size, oraclePrice, marketConfig);
        if (marginUsd < im) {
            revert ErrorUtil.InsufficientMargin();
        }
    }

    /**
     * @dev Performs an ERC20 transfer, deposits collateral to Synthetix, and emits event.
     */
    function transferAndDeposit(
        uint128 marketId,
        uint256 amount,
        address collateralType,
        PerpMarketConfiguration.GlobalData storage globalConfig
    ) private {
        IERC20(collateralType).transferFrom(msg.sender, address(this), amount);
        if (collateralType == address(globalConfig.usdToken)) {
            globalConfig.synthetix.depositMarketUsd(marketId, address(this), amount);
        } else {
            globalConfig.synthetix.depositMarketCollateral(marketId, collateralType, amount);
        }
        emit MarginDeposit(msg.sender, address(this), amount, collateralType);
    }

    /**
     * @dev Performs an collateral withdraw from Synthetix, ERC20 transfer, and emits event.
     */
    function withdrawAndTransfer(
        uint128 marketId,
        uint256 amount,
        address collateralType,
        PerpMarketConfiguration.GlobalData storage globalConfig
    ) private {
        if (collateralType == address(globalConfig.usdToken)) {
            globalConfig.synthetix.withdrawMarketUsd(marketId, address(this), amount);
        } else {
            globalConfig.synthetix.withdrawMarketCollateral(marketId, collateralType, amount);
        }
        IERC20(collateralType).transferFrom(address(this), msg.sender, amount);
        emit MarginWithdraw(address(this), msg.sender, amount, collateralType);
    }

    /**
     * @inheritdoc IMarginModule
     */
    function withdrawAllCollateral(uint128 accountId, uint128 marketId) external {
        Account.loadAccountAndValidatePermission(accountId, AccountRBAC._PERPS_MODIFY_COLLATERAL_PERMISSION);

        PerpMarket.Data storage market = PerpMarket.exists(marketId);

        // Prevent collateral transfers when there's a pending order.
        if (market.orders[accountId].sizeDelta != 0) {
            revert ErrorUtil.OrderFound(accountId);
        }
        // Position is frozen due to prior flagged for liquidation.
        if (market.flaggedLiquidations[accountId] != address(0)) {
            revert ErrorUtil.PositionFlagged();
        }

        // Prevent collateral transfers when there's an open position.
        Position.Data storage position = market.positions[accountId];
        if (position.size != 0) {
            revert ErrorUtil.PositionFound(accountId, marketId);
        }
        (int256 fundingRate, ) = market.recomputeFunding(market.getOraclePrice());
        emit FundingRecomputed(marketId, market.skew, fundingRate, market.getCurrentFundingVelocity());

        Margin.GlobalData storage globalMarginConfig = Margin.load();
        Margin.Data storage accountMargin = Margin.load(accountId, marketId);
        PerpMarketConfiguration.GlobalData storage globalConfig = PerpMarketConfiguration.load();

        uint256 length = globalMarginConfig.supportedAddresses.length;
        address collateralType;
        uint256 available;
        uint256 total;

        for (uint256 i = 0; i < length;) {
            unchecked {
                ++i;
            }
            
            collateralType = globalMarginConfig.supportedAddresses[i];
            available = accountMargin.collaterals[collateralType];
            total += available;
            if (available == 0) {
                continue;
            }

            accountMargin.collaterals[collateralType] -= available;

            // Withdraw all available collateral for this `collateralType`.
            withdrawAndTransfer(marketId, available, collateralType, globalConfig);
        }
        if (total == 0) {
            revert ErrorUtil.NilCollateral();
        }
    }

    /**
     * @inheritdoc IMarginModule
     */
    function modifyCollateral(
        uint128 accountId,
        uint128 marketId,
        address collateralType,
        int256 amountDelta
    ) external {
        Account.loadAccountAndValidatePermission(accountId, AccountRBAC._PERPS_MODIFY_COLLATERAL_PERMISSION);

        PerpMarket.Data storage market = PerpMarket.exists(marketId);

        // Fail fast if the collateralType is empty.
        if (collateralType == address(0)) {
            revert ErrorUtil.ZeroAddress();
        }

        // Prevent collateral transfers when there's a pending order.
        Order.Data storage order = market.orders[accountId];
        if (order.sizeDelta != 0) {
            revert ErrorUtil.OrderFound(accountId);
        }
        // Position is frozen due to prior flagged for liquidation.
        if (market.flaggedLiquidations[accountId] != address(0)) {
            revert ErrorUtil.PositionFlagged();
        }

        PerpMarketConfiguration.GlobalData storage globalConfig = PerpMarketConfiguration.load();
        Margin.GlobalData storage globalMarginConfig = Margin.load();
        Margin.Data storage accountMargin = Margin.load(accountId, marketId);

        uint256 absAmountDelta = MathUtil.abs(amountDelta);
        uint256 availableAmount = accountMargin.collaterals[collateralType];

        Margin.CollateralType storage collateral = globalMarginConfig.supported[collateralType];
        if (collateral.maxAllowable == 0) {
            revert ErrorUtil.UnsupportedCollateral(collateralType);
        }
        if (amountDelta == 0) {
            revert ErrorUtil.ZeroAmount();
        }
        (int256 fundingRate, ) = market.recomputeFunding(market.getOraclePrice());
        emit FundingRecomputed(marketId, market.skew, fundingRate, market.getCurrentFundingVelocity());

        // > 0 is a deposit whilst < 0 is a withdrawal.
        if (amountDelta > 0) {
            // Verify whether this will exceed the maximum allowable collateral amount.
            if (availableAmount + absAmountDelta > collateral.maxAllowable) {
                revert ErrorUtil.MaxCollateralExceeded(absAmountDelta, collateral.maxAllowable);
            }
            accountMargin.collaterals[collateralType] += absAmountDelta;
            transferAndDeposit(marketId, absAmountDelta, collateralType, globalConfig);
        } else {
            // Verify the collateral previously associated to this account is enough to cover withdrawals.
            if (availableAmount < absAmountDelta) {
                revert ErrorUtil.InsufficientCollateral(collateralType, availableAmount, absAmountDelta);
            }

            accountMargin.collaterals[collateralType] -= absAmountDelta;

            // If an open position exists, verify this does _not_ place them into instant liquidation.
            //
            // Ensure we perform this _after_ the accounting update so marginUsd uses with post withdrawal
            // collateral amounts.
            Position.Data storage position = market.positions[accountId];
            if (position.size != 0) {
                validatePositionPostWithdraw(accountId, position, market);
            }

            withdrawAndTransfer(marketId, absAmountDelta, collateralType, globalConfig);
        }
    }

    /**
     * @inheritdoc IMarginModule
     */
    function setCollateralConfiguration(
        address[] calldata collateralTypes,
        bytes32[] calldata oracleNodeIds,
        uint128[] calldata maxAllowables
    ) external {
        OwnableStorage.onlyOwner();
        // Check if all arrays are of the same length
        if (collateralTypes.length != oracleNodeIds.length || collateralTypes.length != maxAllowables.length) {
            revert ErrorUtil.ArrayLengthMismatch();
        }

        PerpMarketConfiguration.GlobalData storage globalMarketConfig = PerpMarketConfiguration.load();
        Margin.GlobalData storage globalMarginConfig = Margin.load();

        // Clear existing collateral configuration to be replaced with new.
        uint256 existingCollateralLength = globalMarginConfig.supportedAddresses.length;
        for (uint256 i = 0; i < existingCollateralLength; ) {
            address collateralType = globalMarginConfig.supportedAddresses[i];
            delete globalMarginConfig.supported[collateralType];

            // Revoke access after wiping collateral from supported market collateral.
            uint256 allowance = IERC20(collateralType).allowance(msg.sender, address(this));
            IERC20(collateralType).decreaseAllowance(address(this), allowance);

            unchecked {
                ++i;
            }
        }
        delete globalMarginConfig.supportedAddresses;

        // Update with passed in configuration.
        uint256 newCollateralLength = collateralTypes.length;
        address[] memory newSupportedAddresses = new address[](newCollateralLength);
        for (uint256 i = 0; i < newCollateralLength; ) {
            address collateralType = collateralTypes[i];
            if (collateralType == address(0)) {
                revert ErrorUtil.ZeroAddress();
            }

            // Perform this operation _once_ when this collateral is added as a supported collateral.
            uint128 maxAllowable = maxAllowables[i];
            uint256 maxUint = type(uint256).max;

            IERC20(collateralType).approve(address(globalMarketConfig.synthetix), maxUint);
            IERC20(collateralType).approve(address(this), maxUint);
            globalMarginConfig.supported[collateralType] = Margin.CollateralType(oracleNodeIds[i], maxAllowable);
            newSupportedAddresses[i] = collateralType;

            unchecked {
                ++i;
            }
        }
        globalMarginConfig.supportedAddresses = newSupportedAddresses;

        emit CollateralConfigured(msg.sender, newCollateralLength);
    }

    // --- Views --- //

    /**
     * @inheritdoc IMarginModule
     */
    function getConfiguredCollaterals() external view returns (AvailableCollateral[] memory) {
        Margin.GlobalData storage globalMarginConfig = Margin.load();

        uint256 length = globalMarginConfig.supportedAddresses.length;
        MarginModule.AvailableCollateral[] memory collaterals = new AvailableCollateral[](length);
        address collateralType;

        for (uint256 i = 0; i < length; ) {
            collateralType = globalMarginConfig.supportedAddresses[i];
            Margin.CollateralType storage c = globalMarginConfig.supported[collateralType];
            collaterals[i] = AvailableCollateral(collateralType, c.oracleNodeId, c.maxAllowable);

            unchecked {
                ++i;
            }
        }

        return collaterals;
    }

    /**
     * @inheritdoc IMarginModule
     */
    function getCollateralUsd(uint128 accountId, uint128 marketId) external view returns (uint256) {
        Account.exists(accountId);
        PerpMarket.exists(marketId);
        return Margin.getCollateralUsd(accountId, marketId);
    }

    /**
     * @inheritdoc IMarginModule
     */
    function getMarginUsd(uint128 accountId, uint128 marketId) external view returns (uint256) {
        Account.exists(accountId);
        PerpMarket.Data storage market = PerpMarket.exists(marketId);
        return Margin.getMarginUsd(accountId, market, market.getOraclePrice());
    }
}
