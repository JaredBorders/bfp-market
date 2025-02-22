//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {DecimalMath} from "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import {SafeCastU256, SafeCastU128, SafeCastI256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {PerpMarketConfiguration} from "./PerpMarketConfiguration.sol";
import {MathUtil} from "../utils/MathUtil.sol";

/**
 * @dev A pending order that awaiting settlement for position modification.
 */
library Order {
    using DecimalMath for uint256;
    using DecimalMath for int256;
    using DecimalMath for int128;
    using SafeCastU128 for uint128;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;

    struct Data {
        int128 sizeDelta;
        uint256 commitmentTime;
        uint256 limitPrice;
        uint256 keeperFeeBufferUsd;
    }

    /**
     * @dev See IOrderModule.fillPrice
     */
    function getFillPrice(int128 skew, uint128 skewScale, int128 size, uint256 price) internal pure returns (uint256) {
        int256 ss = skewScale.toInt();
        int256 p = price.toInt();

        // Calculate pd (premium/discount) before and after trade.
        int256 pdBefore = skew.divDecimal(ss);
        int256 pdAfter = (skew + size).divDecimal(ss);

        // Calculate price before and after trade with pd applied.
        int256 pBefore = p + p.mulDecimal(pdBefore);
        int256 pAfter = p + p.mulDecimal(pdAfter);

        // `fillPrice` is the average of those prices.
        return (pBefore + pAfter).toUint().divDecimal(DecimalMath.UNIT * 2);
    }

    /**
     * @dev See IOrderModule.orderFee
     */
    function getOrderFee(
        int128 sizeDelta,
        uint256 fillPrice,
        int128 skew,
        uint128 makerFee,
        uint128 takerFee
    ) internal pure returns (uint256) {
        int256 notional = sizeDelta.mulDecimal(fillPrice.toInt());

        // Does this trade keep the skew on one side?
        if (MathUtil.sameSide(skew + sizeDelta, skew)) {
            // Use a flat maker/taker fee for the entire size depending on whether the skew is increased or reduced.
            //
            // If the order is submitted on the same side as the skew (increasing it) - the taker fee is charged.
            // otherwise if the order is opposite to the skew, the maker fee is charged.
            uint128 staticRate = MathUtil.sameSide(notional, skew) ? takerFee : makerFee;
            return MathUtil.abs(notional.mulDecimal(staticRate.toInt()));
        }

        // This trade flips the skew.
        //
        // the proportion of size that moves in the direction after the flip should not be considered
        // as a maker (reducing skew) as it's now taking (increasing skew) in the opposite direction. hence,
        // a different fee is applied on the proportion increasing the skew.

        // Proportion of size that's on the other direction.
        uint256 takerSize = MathUtil.abs((skew + sizeDelta).divDecimal(sizeDelta));
        uint256 makerSize = DecimalMath.UNIT - takerSize;

        return
            MathUtil.abs(notional).mulDecimal(takerSize).mulDecimal(takerFee) +
            MathUtil.abs(notional).mulDecimal(makerSize).mulDecimal(makerFee);
    }

    /**
     * @dev Returns the order keeper fee; paid to keepers for order executions and liquidations (in USD).
     *
     * This order keeper fee is calculated as follows:
     *
     * baseKeeperFeeUsd        = keeperSettlementGasUnits * block.basefee * ethOraclePrice
     * boundedBaseKeeperFeeUsd = max(min(minKeeperFeeUsd, baseKeeperFee * (1 + profitMarginPercent) + keeperFeeBufferUsd), maxKeeperFeeUsd)
     *
     * keeperSettlementGasUnits - is a configurable number of gas units to execute a settlement
     * ethOraclePrice           - on-chain oracle price (commitment), pyth price (settlement)
     * keeperFeeBufferUsd       - a user configurable amount in usd to add on top of the base keeper fee
     * min/maxKeeperFeeUsd      - a min/max bound to ensure fee cannot be below min or above max
     *
     * See IOrderModule.getOrderFees for more details.
     */
    function getSettlementKeeperFee(uint256 keeperFeeBufferUsd) internal view returns (uint256) {
        PerpMarketConfiguration.GlobalData storage globalConfig = PerpMarketConfiguration.load();

        uint256 ethPrice = globalConfig.oracleManager.process(globalConfig.ethOracleNodeId).price.toUint();
        uint256 baseKeeperFeeUsd = ethPrice.mulDecimal((globalConfig.keeperSettlementGasUnits * block.basefee * 1e9));
        uint256 baseKeeperFeePlusProfitUsd = baseKeeperFeeUsd.mulDecimal(
            DecimalMath.UNIT + globalConfig.keeperProfitMarginPercent
        ) + keeperFeeBufferUsd;
        uint256 boundedKeeperFeeUsd = MathUtil.min(
            MathUtil.max(globalConfig.minKeeperFeeUsd, baseKeeperFeePlusProfitUsd),
            globalConfig.maxKeeperFeeUsd
        );
        return boundedKeeperFeeUsd;
    }

    // --- Member (mutative) --- //

    /**
     * @dev Updates the current order struct in-place with new data from `data`.
     */
    function update(Order.Data storage self, Order.Data memory data) internal {
        self.commitmentTime = data.commitmentTime;
        self.limitPrice = data.limitPrice;
        self.sizeDelta = data.sizeDelta;
        self.keeperFeeBufferUsd = data.keeperFeeBufferUsd;
    }
}
