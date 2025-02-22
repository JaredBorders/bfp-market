//SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Account} from "@synthetixio/main/contracts/storage/Account.sol";
import {PerpMarket} from "../storage/PerpMarket.sol";
import {Position} from "../storage/Position.sol";
import {Margin} from "../storage/Margin.sol";
import {PerpMarketConfiguration} from "../storage/PerpMarketConfiguration.sol";
import {DecimalMath} from "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import {IPerpAccountModule} from "../interfaces/IPerpAccountModule.sol";
import {MathUtil} from "../utils/MathUtil.sol";

contract PerpAccountModule is IPerpAccountModule {
    using DecimalMath for uint256;
    using PerpMarket for PerpMarket.Data;
    using Position for Position.Data;

    /**
     * @inheritdoc IPerpAccountModule
     */
    function getAccountDigest(
        uint128 accountId,
        uint128 marketId
    ) external view returns (IPerpAccountModule.AccountDigest memory) {
        Account.exists(accountId);
        PerpMarket.Data storage market = PerpMarket.exists(marketId);
        Margin.GlobalData storage globalMarginConfig = Margin.load();
        Margin.Data storage accountMargin = Margin.load(accountId, marketId);

        uint256 length = globalMarginConfig.supportedAddresses.length;
        IPerpAccountModule.DepositedCollateral[] memory collateral = new DepositedCollateral[](length);
        address collateralType;

        for (uint256 i = 0; i < length; ) {
            collateralType = globalMarginConfig.supportedAddresses[i];
            collateral[i] = IPerpAccountModule.DepositedCollateral(
                collateralType,
                accountMargin.collaterals[collateralType],
                Margin.getOraclePrice(collateralType)
            );
            unchecked {
                ++i;
            }
        }

        return
            IPerpAccountModule.AccountDigest(
                collateral,
                Margin.getCollateralUsd(accountId, marketId),
                market.orders[accountId],
                getPositionDigest(accountId, marketId)
            );
    }

    /**
     * @inheritdoc IPerpAccountModule
     */
    function getPositionDigest(
        uint128 accountId,
        uint128 marketId
    ) public view returns (IPerpAccountModule.PositionDigest memory) {
        Account.exists(accountId);
        PerpMarket.Data storage market = PerpMarket.exists(marketId);
        Position.Data storage position = market.positions[accountId];

        uint256 oraclePrice = market.getOraclePrice();
        PerpMarketConfiguration.Data storage marketConfig = PerpMarketConfiguration.load(marketId);

        (uint256 healthFactor, int256 accruedFunding, int256 unrealizedPnl, uint256 remainingMarginUsd) = position
            .getHealthData(market, Margin.getMarginUsd(accountId, market, oraclePrice), oraclePrice, marketConfig);
        uint256 notionalValueUsd = MathUtil.abs(position.size).mulDecimal(oraclePrice);
        (uint256 im, uint256 mm, ) = Position.getLiquidationMarginUsd(position.size, oraclePrice, marketConfig);

        return
            IPerpAccountModule.PositionDigest(
                accountId,
                marketId,
                remainingMarginUsd,
                healthFactor,
                notionalValueUsd,
                unrealizedPnl,
                accruedFunding,
                position.entryPrice,
                oraclePrice,
                position.size,
                im,
                mm
            );
    }
}
