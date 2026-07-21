//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FullMath} from "../src/compat/FullMath.sol";
import {TickMath} from "../src/compat/TickMath.sol";
import "forge-std/console.sol";

interface IUniswapV3Pool {
    function observe(uint32[] calldata secondsAgos) 
    external
    view
    returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract TWAPOracle {
    IUniswapV3Pool public immutable pool;
    IUniswapV2Pair public immutable pair;

    bool public immutable isV3;
    bool public immutable isV2Token0Base;

    uint32 public immutable twapPeriod;
    uint32 public immutable fastTwapPeriod;
    uint256 public constant PRECISION = 1e18;

    uint256 private constant MIN_SQRT_RATIO_BOUND = (1 << 32) + 512;
    uint256 private constant MAX_SQRT_RATIO_BOUND = type(uint160).max;

    error InvalidTargetPool();
    error InvalidTwapPeriod();
    error SafeCastOverflow();

    constructor(address _target, address _vaultBaseToken, bool _isV3, uint32 _twapPeriod, uint32 _fastTwapPeriod) {
        if(_target == address(0)) revert InvalidTargetPool();
        if(_twapPeriod == 0 || _fastTwapPeriod == 0) revert InvalidTwapPeriod();
        
        isV3 = _isV3;
        twapPeriod = _twapPeriod;
        fastTwapPeriod = _fastTwapPeriod;

        if(isV3){
            pool = IUniswapV3Pool(_target);
            pair = IUniswapV2Pair(address(0));
            isV2Token0Base = false;
        }else{
            pair = IUniswapV2Pair(_target);
            pool = IUniswapV3Pool(address(0));
            isV2Token0Base = (IUniswapV2Pair(_target).token0() == _vaultBaseToken);
        }
    }

    function getTwapTick() external view returns (int24 arithmeticMeanTick){
        if(isV3){
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapPeriod;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 int24Period = _safeCastToInt24(int256(uint256(twapPeriod)));
        arithmeticMeanTick = _safeCastToInt24(tickCumulativesDelta / int24Period);

        if(tickCumulativesDelta < 0 && (tickCumulativesDelta % int24Period) != 0){
            arithmeticMeanTick--;
        }
        }else {
            arithmeticMeanTick = _getV2VirtualTick();
        }
    }

    function getFastTwapTick() external view returns (int24 fastMeanTick){
        if(isV3){
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = fastTwapPeriod;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 int24Period = _safeCastToInt24(int256(uint256(fastTwapPeriod)));
        fastMeanTick = _safeCastToInt24(tickCumulativesDelta / int24Period);

        if(tickCumulativesDelta < 0 && (tickCumulativesDelta % int24Period) != 0){
            fastMeanTick--;
        }
        }else {
            fastMeanTick = _getV2VirtualTick();
        }
    }

    function _getV2VirtualTick() internal view returns (int24 virtualTick){
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) return 0;
        
        uint256 priceX64;

        if(isV2Token0Base) {
            priceX64 = FullMath.mulDiv(uint256(reserve1), uint256(1) << 64, uint256(reserve0));
        }else {
            priceX64 = FullMath.mulDiv(uint256(reserve0), uint256(1) << 64, uint256(reserve1));
        }

        uint256 sqrtPriceX96 = _sqrt(priceX64) << 64;

        sqrtPriceX96 = _clampSqrtRatio(sqrtPriceX96);

        virtualTick = TickMath.getTickAtSqrtRatio(uint160(sqrtPriceX96));
        
    }

    function _safeCastToInt24(int256 value) internal pure returns (int24) {
        if (value < type(int24).min || value >type(int24).max) revert SafeCastOverflow();
        return int24(value);
    }

    function _clampSqrtRatio(uint256 _sqrtPriceX96) internal pure returns (uint256 clampedPrice) {
        clampedPrice = _sqrtPriceX96;

        if (clampedPrice <= MIN_SQRT_RATIO_BOUND) {
            clampedPrice = MIN_SQRT_RATIO_BOUND + 1;
        }

        if (clampedPrice >= MAX_SQRT_RATIO_BOUND) {
            clampedPrice = MAX_SQRT_RATIO_BOUND - 1;
        }
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

}