//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import "./IBasePerpMarket.sol";

interface IPerpCollateralModule is IBasePerpMarket {
    // --- Structs --- //

    struct AvailableCollateral {
        // Address of the available collateral.
        address collateralType;
        // Oracle price feed node id.
        bytes32 oracleNodeId;
        // Maximum allowable deposited amount.
        uint128 maxAllowable;
    }

    // --- Events --- //

    // @dev Emitted when collateral is transferred between user <-> Account.
    event Transfer(address indexed from, address indexed to, int256 value);

    // --- Errors --- //

    // @dev Emitted when supplied configuration is incorrect.
    error InvalidConfiguration();

    // @dev Thrown when an account has insufficient collateral to transfer.
    error InsufficientCollateral(int256 collateral, int256 value);

    // @dev Thrown when attempting to deposit a collateral that has reached a max deportable amount.
    error MaxCollateralExceeded(int256 value, uint256 max);

    // --- Mutative --- //

    /**
     * @dev Transfers an accepted `collateral` from msg.sender to `accountId` on a specific `marketId`.
     *
     * A negative `amountDelta` is a withdrawal. A variety of errors are thrown if limits or collateral
     * issues are found. A transfer, even when there is no open position will immediately deposit the
     * collateral into the Synthetix core system.
     *
     * There are no fees associated with the transfer of collateral.
     */
    function transferTo(uint128 accountId, uint128 marketId, address collateral, int256 amountDelta) external;

    /**
     * @dev Configure PerpCollateral with collateral types and their allowables.
     */
    function setCollateralConfiguration(
        address[] calldata collateralTypes,
        bytes32[] calldata oracleNodeIds,
        uint128[] calldata maxAllowables
    ) external;

    // --- Views --- //

    function getConfiguredCollaterals() external view returns (AvailableCollateral[] memory collaterals);
}
