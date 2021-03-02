/**
 * SPDX-License-Identifier: UNLICENSED
 */
pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;

import {SafeMath} from "./packages/oz/SafeMath.sol";
import {OtokenInterface} from "./interfaces/OtokenInterface.sol";
import {OracleInterface} from "./interfaces/OracleInterface.sol";
import {ERC20Interface} from "./interfaces/ERC20Interface.sol";
import {FixedPointInt256 as FPI} from "./libs/FixedPointInt256.sol";
import {MarginVault} from "./libs/MarginVault.sol";

/**
 * @title MarginCalculator
 * @author Opyn
 * @notice Calculator module that checks if a given vault is valid, calculates margin requirements, and settlement proceeds
 */
contract MarginCalculator {
    using SafeMath for uint256;
    using FPI for FPI.FixedPointInt;

    /// @dev oracle module
    OracleInterface public oracle;

    /// @dev decimals used by strike price and oracle price
    uint256 internal constant BASE = 8;

    /// @dev FixedPoint 0
    FPI.FixedPointInt internal ZERO = FPI.fromScaledUint(0, BASE);

    struct VaultDetails {
        address shortUnderlyingAsset;
        address shortStrikeAsset;
        address shortCollateralAsset;
        address longUnderlyingAsset;
        address longStrikeAsset;
        address longCollateralAsset;
        uint256 shortStrikePrice;
        uint256 shortExpiryTimestamp;
        uint256 shortCollateralDecimals;
        uint256 longStrikePrice;
        uint256 longExpiryTimestamp;
        uint256 longCollateralDecimals;
        uint256 collateralDecimals;
        bool isShortPut;
        bool isLongPut;
        bool hasLong;
        bool hasShort;
        bool hasCollateral;
    }

    uint256[] internal ptimes = [
        // one day
        86400,
        // three days
        259200,
        // one week
        604800,
        // two weeks
        1209600,
        // four weeks
        2419200
    ];

    mapping(uint256 => uint256) internal pvalues;
    uint256 internal pvalueDecimals = 12;
    // auction length (set to one day)
    uint256 internal AUCTION_LENGTH = 86400;

    constructor(address _oracle) public {
        require(_oracle != address(0), "MarginCalculator: invalid oracle address");

        oracle = OracleInterface(_oracle);

        // pvalues have twelve decimals
        pvalues[86400] = 52166761235;
        pvalues[259200] = 90226787871;
        pvalues[604800] = 137432041436;
        pvalues[1209600] = 193395770533;
        pvalues[2419200] = 281783870466;
    }

    /**
     * @notice return the cash value of an expired oToken, denominated in collateral
     * @param _otoken oToken address
     * @return how much collateral can be taken out by 1 otoken unit, scaled by 1e8,
     * or how much collateral can be taken out for 1 (1e8) oToken
     */
    function getExpiredPayoutRate(address _otoken) external view returns (uint256) {
        require(_otoken != address(0), "MarginCalculator: Invalid token address");

        OtokenInterface otoken = OtokenInterface(_otoken);

        (
            address collateral,
            address underlying,
            address strikeAsset,
            uint256 strikePrice,
            uint256 expiry,
            bool isPut
        ) = otoken.getOtokenDetails();

        require(now > expiry, "MarginCalculator: Otoken not expired yet");

        FPI.FixedPointInt memory cashValueInStrike = _getExpiredCashValue(
            underlying,
            strikeAsset,
            expiry,
            strikePrice,
            isPut
        );

        FPI.FixedPointInt memory cashValueInCollateral = _convertAmountOnExpiryPrice(
            cashValueInStrike,
            strikeAsset,
            collateral,
            expiry
        );

        // the exchangeRate was scaled by 1e8, if 1e8 otoken can take out 1 USDC, the exchangeRate is currently 1e8
        // we want to return: how much USDC units can be taken out by 1 (1e8 units) oToken
        uint256 collateralDecimals = uint256(ERC20Interface(collateral).decimals());
        return cashValueInCollateral.toScaledUint(collateralDecimals, true);
    }

    /**
     * @notice returns the amount of collateral that can be removed from an actual or a theoretical vault
     * @dev return amount is denominated in the collateral asset for the oToken in the vault, or the collateral asset in the vault
     * @param _vault theoretical vault that needs to be checked
     * @return excessCollateral the amount by which the margin is above or below the required amount
     * @return isExcess True if there is excess margin in the vault, False if there is a deficit of margin in the vault
     * if True, collateral can be taken out from the vault, if False, additional collateral needs to be added to vault
     */
    function getExcessCollateral(MarginVault.Vault memory _vault, uint256 _marginType)
        public
        view
        returns (uint256, bool)
    {
        // get vault details
        VaultDetails memory vaultDetails = getVaultDetails(_vault);
        // include all the checks for to ensure the vault is valid
        _checkIsValidVault(_vault, vaultDetails);

        // if the vault contains no oTokens, return the amount of collateral
        if (!vaultDetails.hasShort && !vaultDetails.hasLong) {
            uint256 amount = vaultDetails.hasCollateral ? _vault.collateralAmounts[0] : 0;
            return (amount, true);
        }

        FPI.FixedPointInt memory collateralAmount = ZERO;
        if (vaultDetails.hasCollateral) {
            collateralAmount = FPI.fromScaledUint(_vault.collateralAmounts[0], vaultDetails.collateralDecimals);
        }

        // get required margin, denominated in collateral
        FPI.FixedPointInt memory collateralRequired = _getMarginRequired(_vault, vaultDetails, _marginType);
        FPI.FixedPointInt memory excessCollateral = collateralAmount.sub(collateralRequired);

        bool isExcess = excessCollateral.isGreaterThanOrEqual(ZERO);
        uint256 collateralDecimals = vaultDetails.hasLong
            ? vaultDetails.longCollateralDecimals
            : vaultDetails.shortCollateralDecimals;
        // if is excess, truncate the tailing digits in excessCollateralExternal calculation
        uint256 excessCollateralExternal = excessCollateral.toScaledUint(collateralDecimals, isExcess);
        return (excessCollateralExternal, isExcess);
    }

    /**
     * @notice return the cash value of an expired oToken, denominated in strike asset
     * @dev for a call, return Max (0, underlyingPriceInStrike - otoken.strikePrice)
     * @dev for a put, return Max(0, otoken.strikePrice - underlyingPriceInStrike)
     * @param _underlying otoken underlying asset
     * @param _strike otoken strike asset
     * @param _expiryTimestamp otoken expiry timestamp
     * @param _strikePrice otoken strike price
     * @param _strikePrice true if otoken is put otherwise false
     * @return cash value of an expired otoken, denominated in the strike asset
     */
    function _getExpiredCashValue(
        address _underlying,
        address _strike,
        uint256 _expiryTimestamp,
        uint256 _strikePrice,
        bool _isPut
    ) internal view returns (FPI.FixedPointInt memory) {
        // strike price is denominated in strike asset
        FPI.FixedPointInt memory strikePrice = FPI.fromScaledUint(_strikePrice, BASE);
        FPI.FixedPointInt memory one = FPI.fromScaledUint(1, 0);

        // calculate the value of the underlying asset in terms of the strike asset
        FPI.FixedPointInt memory underlyingPriceInStrike = _convertAmountOnExpiryPrice(
            one, // underlying price denominated in underlying
            _underlying,
            _strike,
            _expiryTimestamp
        );

        if (_isPut) {
            return strikePrice.isGreaterThan(underlyingPriceInStrike) ? strikePrice.sub(underlyingPriceInStrike) : ZERO;
        } else {
            return underlyingPriceInStrike.isGreaterThan(strikePrice) ? underlyingPriceInStrike.sub(strikePrice) : ZERO;
        }
    }

    function _getExpiredVaultProceeds(MarginVault.Vault memory _vault, VaultDetails memory _vaultDetails)
        internal
        view
        returns (FPI.FixedPointInt memory)
    {
        uint256 otokenExpiry = _vaultDetails.hasShort
            ? _vaultDetails.shortExpiryTimestamp
            : _vaultDetails.longExpiryTimestamp;

        FPI.FixedPointInt memory shortAmount = _vaultDetails.hasShort
            ? FPI.fromScaledUint(_vault.shortAmounts[0], BASE)
            : ZERO;
        FPI.FixedPointInt memory longAmount = _vaultDetails.hasLong
            ? FPI.fromScaledUint(_vault.longAmounts[0], BASE)
            : ZERO;
        // address otokenUnderlyingAsset = _vaultDetails.hasShort
        //     ? _vaultDetails.shortUnderlyingAsset
        //     : _vaultDetails.longUnderlyingAsset;
        address otokenCollateralAsset = _vaultDetails.hasShort
            ? _vaultDetails.shortCollateralAsset
            : _vaultDetails.longCollateralAsset;
        address otokenStrikeAsset = _vaultDetails.hasShort
            ? _vaultDetails.shortStrikeAsset
            : _vaultDetails.longStrikeAsset;
        bool isPut = _vaultDetails.hasShort ? _vaultDetails.isShortPut : _vaultDetails.isLongPut;

        FPI.FixedPointInt memory valueInStrike;
        FPI.FixedPointInt memory shortCashValue;
        {
            shortCashValue = _vaultDetails.hasShort
                ? _getExpiredCashValue(
                    _vaultDetails.shortUnderlyingAsset,
                    _vaultDetails.shortStrikeAsset,
                    _vaultDetails.shortExpiryTimestamp,
                    _vaultDetails.shortStrikePrice,
                    isPut
                )
                : ZERO;
            FPI.FixedPointInt memory longCashValue = _vaultDetails.hasLong
                ? _getExpiredCashValue(
                    _vaultDetails.longUnderlyingAsset,
                    _vaultDetails.longStrikeAsset,
                    _vaultDetails.longExpiryTimestamp,
                    _vaultDetails.longStrikePrice,
                    isPut
                )
                : ZERO;
            valueInStrike = _getExpiredSpreadCashValue(shortAmount, longAmount, shortCashValue, longCashValue);
        }

        // convert amount to be denominated in collateral
        return _convertAmountOnExpiryPrice(valueInStrike, otokenStrikeAsset, otokenCollateralAsset, otokenExpiry);
    }

    /**
     * @notice calculate the amount of collateral needed for a vault
     * @dev vault passed in has already passed the checkIsValidVault function
     * @param _vault theoretical vault that needs to be checked
     * @return marginRequired the minimal amount of collateral needed in a vault, denominated in collateral
     */
    function _getMarginRequired(
        MarginVault.Vault memory _vault,
        VaultDetails memory _vaultDetails,
        uint256 _marginType
    ) internal view returns (FPI.FixedPointInt memory) {
        uint256 otokenExpiry = _vaultDetails.hasShort
            ? _vaultDetails.shortExpiryTimestamp
            : _vaultDetails.longExpiryTimestamp;

        if (now > otokenExpiry) return _getExpiredVaultProceeds(_vault, _vaultDetails);

        FPI.FixedPointInt memory shortAmount = _vaultDetails.hasShort
            ? FPI.fromScaledUint(_vault.shortAmounts[0], BASE)
            : ZERO;
        FPI.FixedPointInt memory longAmount = _vaultDetails.hasLong
            ? FPI.fromScaledUint(_vault.longAmounts[0], BASE)
            : ZERO;
        address otokenUnderlyingAsset = _vaultDetails.hasShort
            ? _vaultDetails.shortUnderlyingAsset
            : _vaultDetails.longUnderlyingAsset;
        address otokenCollateralAsset = _vaultDetails.hasShort
            ? _vaultDetails.shortCollateralAsset
            : _vaultDetails.longCollateralAsset;
        address otokenStrikeAsset = _vaultDetails.hasShort
            ? _vaultDetails.shortStrikeAsset
            : _vaultDetails.longStrikeAsset;
        bool isPut = _vaultDetails.hasShort ? _vaultDetails.isShortPut : _vaultDetails.isLongPut;

        // max loss
        if (_marginType == 0) {
            FPI.FixedPointInt memory shortStrike = _vaultDetails.hasShort
                ? FPI.fromScaledUint(_vaultDetails.shortStrikePrice, BASE)
                : ZERO;
            FPI.FixedPointInt memory longStrike = _vaultDetails.hasLong
                ? FPI.fromScaledUint(_vaultDetails.longStrikePrice, BASE)
                : ZERO;

            if (isPut) {
                FPI.FixedPointInt memory strikeNeeded = _getPutSpreadMarginRequired(
                    shortAmount,
                    longAmount,
                    shortStrike,
                    longStrike
                );
                // convert amount to be denominated in collateral
                return _convertAmountOnLivePrice(strikeNeeded, otokenStrikeAsset, otokenCollateralAsset);
            } else {
                FPI.FixedPointInt memory underlyingNeeded = _getCallSpreadMarginRequired(
                    shortAmount,
                    longAmount,
                    shortStrike,
                    longStrike
                );
                // convert amount to be denominated in collateral
                return _convertAmountOnLivePrice(underlyingNeeded, otokenUnderlyingAsset, otokenCollateralAsset);
            }
        }
        // naked margin
        if (_marginType == 1) {
            // get current price
            uint256 collateralRequiredPerOtoken;
            uint256 shortCollateralDecimals = _vaultDetails.shortCollateralDecimals;
            {
                uint256 currentPrice = oracle.getPrice(_vaultDetails.shortUnderlyingAsset);
                collateralRequiredPerOtoken = getNakedMarginRequirements(
                    _vaultDetails.shortStrikePrice,
                    currentPrice,
                    otokenExpiry.sub(now),
                    isPut,
                    shortCollateralDecimals
                );
            }
            return FPI.fromScaledUint(collateralRequiredPerOtoken, shortCollateralDecimals).mul(shortAmount);
        }
        // else
        revert("MarginCalculator: invalid vaultType");
    }

    /**
     * @dev returns the strike asset amount of margin required for a put or put spread with the given short oTokens, long oTokens and amounts
     *
     * marginRequired = max( (short amount * short strike) - (long strike * min (short amount, long amount)) , 0 )
     *
     * @return margin requirement denominated in the strike asset
     */
    function _getPutSpreadMarginRequired(
        FPI.FixedPointInt memory _shortAmount,
        FPI.FixedPointInt memory _longAmount,
        FPI.FixedPointInt memory _shortStrike,
        FPI.FixedPointInt memory _longStrike
    ) internal view returns (FPI.FixedPointInt memory) {
        return FPI.max(_shortAmount.mul(_shortStrike).sub(_longStrike.mul(FPI.min(_shortAmount, _longAmount))), ZERO);
    }

    /**
     * @dev returns the underlying asset amount required for a call or call spread with the given short oTokens, long oTokens, and amounts
     *
     *                           (long strike - short strike) * short amount
     * marginRequired =  max( ------------------------------------------------- , max (short amount - long amount, 0) )
     *                                           long strike
     *
     * @dev if long strike = 0, return max( short amount - long amount, 0)
     * @return margin requirement denominated in the underlying asset
     */
    function _getCallSpreadMarginRequired(
        FPI.FixedPointInt memory _shortAmount,
        FPI.FixedPointInt memory _longAmount,
        FPI.FixedPointInt memory _shortStrike,
        FPI.FixedPointInt memory _longStrike
    ) internal view returns (FPI.FixedPointInt memory) {
        // max (short amount - long amount , 0)
        if (_longStrike.isEqual(ZERO)) {
            return FPI.max(_shortAmount.sub(_longAmount), ZERO);
        }

        /**
         *             (long strike - short strike) * short amount
         * calculate  ----------------------------------------------
         *                             long strike
         */
        FPI.FixedPointInt memory firstPart = _longStrike.sub(_shortStrike).mul(_shortAmount).div(_longStrike);

        /**
         * calculate max ( short amount - long amount , 0)
         */
        FPI.FixedPointInt memory secondPart = FPI.max(_shortAmount.sub(_longAmount), ZERO);

        return FPI.max(firstPart, secondPart);
    }

    /**
     * @dev calculate the cash value obligation for an expired vault, where a positive number is an obligation
     *
     * Formula: net = (short cash value * short amount) - ( long cash value * long Amount )
     *
     * @return cash value obligation denominated in the strike asset
     */
    function _getExpiredSpreadCashValue(
        FPI.FixedPointInt memory _shortAmount,
        FPI.FixedPointInt memory _longAmount,
        FPI.FixedPointInt memory _shortCashValue,
        FPI.FixedPointInt memory _longCashValue
    ) internal pure returns (FPI.FixedPointInt memory) {
        return _shortCashValue.mul(_shortAmount).sub(_longCashValue.mul(_longAmount));
    }

    /**
     * @dev ensure that:
     * a) at most 1 asset type used as collateral
     * b) at most 1 series of option used as the long option
     * c) at most 1 series of option used as the short option
     * d) asset array lengths match for long, short and collateral
     * e) long option and collateral asset is acceptable for margin with short asset
     * @param _vault the vault to check
     */
    function _checkIsValidVault(MarginVault.Vault memory _vault, VaultDetails memory _vaultDetails) internal view {
        // ensure all the arrays in the vault are valid
        require(_vault.shortOtokens.length <= 1, "MarginCalculator: Too many short otokens in the vault");
        require(_vault.longOtokens.length <= 1, "MarginCalculator: Too many long otokens in the vault");
        require(_vault.collateralAssets.length <= 1, "MarginCalculator: Too many collateral assets in the vault");

        require(
            _vault.shortOtokens.length == _vault.shortAmounts.length,
            "MarginCalculator: Short asset and amount mismatch"
        );
        require(
            _vault.longOtokens.length == _vault.longAmounts.length,
            "MarginCalculator: Long asset and amount mismatch"
        );
        require(
            _vault.collateralAssets.length == _vault.collateralAmounts.length,
            "MarginCalculator: Collateral asset and amount mismatch"
        );

        // ensure the long asset is valid for the short asset
        require(
            _isMarginableLong(_vault, _vaultDetails),
            "MarginCalculator: long asset not marginable for short asset"
        );

        // ensure that the collateral asset is valid for the short asset
        require(
            _isMarginableCollateral(_vault, _vaultDetails),
            "MarginCalculator: collateral asset not marginable for short asset"
        );
    }

    /**
     * @dev if there is a short option and a long option in the vault, ensure that the long option is able to be used as collateral for the short option
     * @param _vault the vault to check.
     */
    function _isMarginableLong(MarginVault.Vault memory _vault, VaultDetails memory _vaultDetails)
        internal
        view
        returns (bool)
    {
        // if vault is missing a long or a short, return True
        if (!_vaultDetails.hasLong || !_vaultDetails.hasShort) return true;

        return
            _vault.longOtokens[0] != _vault.shortOtokens[0] &&
            _vaultDetails.longUnderlyingAsset == _vaultDetails.shortUnderlyingAsset &&
            _vaultDetails.longStrikeAsset == _vaultDetails.shortStrikeAsset &&
            _vaultDetails.longCollateralAsset == _vaultDetails.shortCollateralAsset &&
            _vaultDetails.longExpiryTimestamp == _vaultDetails.shortExpiryTimestamp &&
            _vaultDetails.isLongPut == _vaultDetails.isShortPut;
    }

    /**
     * @dev if there is short option and collateral asset in the vault, ensure that the collateral asset is valid for the short option
     * @param _vault the vault to check.
     */
    function _isMarginableCollateral(MarginVault.Vault memory _vault, VaultDetails memory _vaultDetails)
        internal
        view
        returns (bool)
    {
        bool isMarginable = true;

        if (!_vaultDetails.hasCollateral) return isMarginable;

        if (_vaultDetails.hasShort) {
            isMarginable = _vaultDetails.shortCollateralAsset == _vault.collateralAssets[0];
        } else if (_vaultDetails.hasLong) {
            isMarginable = _vaultDetails.longCollateralAsset == _vault.collateralAssets[0];
        }

        return isMarginable;
    }

    /**
     * @notice convert an amount in asset A to equivalent amount of asset B, based on a live price
     * @dev function includes the amount and applies .mul() first to increase the accuracy
     * @param _amount amount in asset A
     * @param _assetA asset A
     * @param _assetB asset B
     * @return _amount in asset B
     */
    function _convertAmountOnLivePrice(
        FPI.FixedPointInt memory _amount,
        address _assetA,
        address _assetB
    ) internal view returns (FPI.FixedPointInt memory) {
        if (_assetA == _assetB) {
            return _amount;
        }
        uint256 priceA = oracle.getPrice(_assetA);
        uint256 priceB = oracle.getPrice(_assetB);
        // amount A * price A in USD = amount B * price B in USD
        // amount B = amount A * price A / price B
        return _amount.mul(FPI.fromScaledUint(priceA, BASE)).div(FPI.fromScaledUint(priceB, BASE));
    }

    /**
     * @notice convert an amount in asset A to equivalent amount of asset B, based on an expiry price
     * @dev function includes the amount and apply .mul() first to increase the accuracy
     * @param _amount amount in asset A
     * @param _assetA asset A
     * @param _assetB asset B
     * @return _amount in asset B
     */
    function _convertAmountOnExpiryPrice(
        FPI.FixedPointInt memory _amount,
        address _assetA,
        address _assetB,
        uint256 _expiry
    ) internal view returns (FPI.FixedPointInt memory) {
        if (_assetA == _assetB) {
            return _amount;
        }
        (uint256 priceA, bool priceAFinalized) = oracle.getExpiryPrice(_assetA, _expiry);
        (uint256 priceB, bool priceBFinalized) = oracle.getExpiryPrice(_assetB, _expiry);
        require(priceAFinalized && priceBFinalized, "MarginCalculator: price at expiry not finalized yet.");
        // amount A * price A in USD = amount B * price B in USD
        // amount B = amount A * price A / price B
        return _amount.mul(FPI.fromScaledUint(priceA, BASE)).div(FPI.fromScaledUint(priceB, BASE));
    }

    /**
     * @dev check if asset array contain a token address
     * @return True if the array is not empty
     */
    function _isNotEmpty(address[] memory _assets) internal pure returns (bool) {
        return _assets.length > 0 && _assets[0] != address(0);
    }

    function getVaultDetails(MarginVault.Vault memory _vault) internal view returns (VaultDetails memory) {
        VaultDetails memory vaultDetails = VaultDetails(
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0),
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            false,
            false,
            false,
            false,
            false
        );

        vaultDetails.hasLong = _isNotEmpty(_vault.longOtokens);
        vaultDetails.hasShort = _isNotEmpty(_vault.shortOtokens);
        vaultDetails.hasCollateral = _isNotEmpty(_vault.collateralAssets);

        if (vaultDetails.hasLong) {
            OtokenInterface long = OtokenInterface(_vault.longOtokens[0]);
            (
                vaultDetails.longCollateralAsset,
                vaultDetails.longUnderlyingAsset,
                vaultDetails.longStrikeAsset,
                vaultDetails.longStrikePrice,
                vaultDetails.longExpiryTimestamp,
                vaultDetails.isLongPut
            ) = long.getOtokenDetails();
            vaultDetails.longCollateralDecimals = uint256(ERC20Interface(vaultDetails.longCollateralAsset).decimals());
        }

        if (vaultDetails.hasShort) {
            OtokenInterface short = OtokenInterface(_vault.shortOtokens[0]);
            (
                vaultDetails.shortCollateralAsset,
                vaultDetails.shortUnderlyingAsset,
                vaultDetails.shortStrikeAsset,
                vaultDetails.shortStrikePrice,
                vaultDetails.shortExpiryTimestamp,
                vaultDetails.isShortPut
            ) = short.getOtokenDetails();
            vaultDetails.shortCollateralDecimals = uint256(
                ERC20Interface(vaultDetails.shortCollateralAsset).decimals()
            );
        }

        if (vaultDetails.hasCollateral) {
            vaultDetails.collateralDecimals = uint256(ERC20Interface(_vault.collateralAssets[0]).decimals());
        }

        return vaultDetails;
    }

    // gets the margin requirements given a historical roundId
    function getHistoricalExcessNakedMargin(
        MarginVault.Vault memory _vault,
        uint256 _price,
        uint256 _timestamp
    ) public view returns (uint256, bool) {
        VaultDetails memory vaultDetails = getVaultDetails(_vault);

        require(vaultDetails.hasShort, "MarginCalculator: Vault has no short token");
        require(
            vaultDetails.shortExpiryTimestamp > _timestamp,
            "MarginCalculator: short token was expired at the timestamp"
        );
        _checkIsValidVault(_vault, vaultDetails);

        uint256 shortAmount = _vault.shortAmounts[0];
        uint256 collateralAmount = _vault.collateralAmounts[0];
        uint256 collateralRequiredPerOtoken = getNakedMarginRequirements(
            vaultDetails.shortStrikePrice,
            _price,
            vaultDetails.shortExpiryTimestamp.sub(_timestamp),
            vaultDetails.isShortPut,
            vaultDetails.shortCollateralDecimals
        );

        uint256 collateralRequired = collateralRequiredPerOtoken.mul(shortAmount).div(10**BASE);
        if (collateralAmount > collateralRequired) {
            return (collateralAmount.sub(collateralRequired), true);
        } else {
            return (collateralRequired.sub(collateralAmount), false);
        }
    }

    /**
     * @dev returns the partial collateralization requirements per otoken
     * does not depend on the partiuclar vault
     * @param strike, the strike price of the otoken
     * @param spot the spot price of the underlying
     * @param timeToExpiry time until expiry of the option
     * @param isPut true if the otoken is a put
     */
    function getNakedMarginRequirements(
        uint256 strike,
        uint256 spot,
        uint256 timeToExpiry,
        bool isPut,
        uint256 collateralDecimals
    ) public view returns (uint256) {
        if (isPut) {
            // if isPut return value will have collateral decimals
            if (strike < spot.mul(3).div(4)) {
                // p(t) * K
                return _p(timeToExpiry).mul(strike).mul(10**collateralDecimals).div(10**BASE).div(10**12);
            } else {
                // p(t) * (.75 * S) + (K - .75 * S)
                uint256 A = _p(timeToExpiry).mul(3).mul(spot).div(4).div(10**12).add(strike.sub(spot.mul(3).div(4)));
                return A.mul(10**collateralDecimals).div(10**BASE);
            }
        } else {
            // if (!isPut) return value will have collateral decimals
            if (spot > strike.mul(4).div(3)) {
                // shortCollateralDecimals
                // output needs to be in underlying decimals, strike and spot are in strike decimals (BASE).
                // 1 - (4/3)(K/S) + P(t) * (4/3)(K/S) = 1 - (1 -p(t))(4/3)(K/S)
                uint256 A = (10**collateralDecimals).sub(
                    _p(timeToExpiry).mul(10**collateralDecimals).div(10**pvalueDecimals)
                );
                uint256 B = A.mul(4).mul(strike).div(3).div(spot);
                return (10**collateralDecimals).sub(B);
            } else {
                // simply p(t) in collateral decimals
                return _p(timeToExpiry).mul(10**collateralDecimals).div(10**pvalueDecimals);
            }
        }
    }

    // p values have twelve decimals
    function _p(uint256 timeToExpiry) internal view returns (uint256) {
        uint256 i = 0;
        while (i < ptimes.length && ptimes[i] < timeToExpiry) {
            i++;
        }
        require(i < ptimes.length, "MarginCalculator: timeToExpiry out of range");
        return pvalues[ptimes[i]];
    }

    // /**
    //  * @notice convert an amount of otoken to current amount of collateral, based on historical price
    //  * @param _vault, the vault to be liquidated
    //  * @param roundId  the historical chainlink roundId
    //  * @param amount the amount of otoken debt to offer.
    //  * @return the amount of collateral the liquidator receives for a single otoken
    //  */
    uint256 internal deviationFactor = 1;
    uint256 internal deviationDecimals = 2;

    function getLiquidationAmount(
        MarginVault.Vault memory _vault,
        uint256 _amount,
        uint256 _roundId,
        uint256 _lastCheckedMargin
    ) external view returns (uint256) {
        VaultDetails memory vaultDetails = getVaultDetails(_vault);
        require(_amount > 0, "MarginCalculator: amount must be positive");
        require(vaultDetails.hasShort, "MarginCalculator: Vault has no short token");
        require(now < vaultDetails.shortExpiryTimestamp, "MarginCalculator: short otoken has already expired");

        (uint256 price, uint256 startTime) = oracle.getHistoricalPrice(vaultDetails.shortUnderlyingAsset, _roundId);

        require(startTime < now, "MarginCalculator: invalid startTime");
        uint256 timeElapsed = now.sub(startTime);
        require(
            startTime > _lastCheckedMargin,
            "MarginCalculator: vault was adjusted more recently than the timestamp of the historical price"
        );

        (, bool isExcess) = getHistoricalExcessNakedMargin(_vault, price, startTime);
        require(!isExcess, "MarginCalculator: vault was not under-collateralized at the roundId");

        uint256 B = _vault.collateralAmounts[0].mul(10**BASE).div(_vault.shortAmounts[0]);
        uint256 salePrice;
        if (timeElapsed > AUCTION_LENGTH) {
            salePrice = B;
        } else {
            uint256 deviation = deviationFactor.mul(price).div(10**deviationDecimals);
            uint256 strike = vaultDetails.shortStrikePrice;
            uint256 A;
            if (vaultDetails.isShortPut) {
                // put, usdc
                if (strike <= price + deviation)
                    A = 0;
                    // CV - D*S
                else A = strike.sub(price).sub(deviation).mul(10**vaultDetails.collateralDecimals).div(10**BASE);
            } else {
                // call
                if (strike <= price + deviation)
                    A = 0;
                    // (CV - D*S)/S
                else A = strike.sub(price).sub(deviation).mul(10**vaultDetails.collateralDecimals).div(price);
            }
            // interpolate from A to B
            if (A > B) salePrice = B;
            else salePrice = A.add(timeElapsed.mul(B.sub(A)).div(AUCTION_LENGTH));
        }

        return salePrice.mul(_amount).div(10**BASE);
    }

    function verifyDustLimit(MarginVault.Vault memory _vault) external view returns (bool) {
        if (_vault.collateralAssets.length == 0) return true;
        require(
            oracle.getDustLimit(_vault.collateralAssets[0]) > 0,
            "MarginCalculator: unsupported asset, no dust limit"
        );
        if (_vault.collateralAmounts[0] > oracle.getDustLimit(_vault.collateralAssets[0])) return true;
        return false;
    }
}
