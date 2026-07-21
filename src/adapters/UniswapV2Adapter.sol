//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol"; 
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVenueAdapter} from "../interface/IVenueAdapter.sol";
import {FullMath} from "../compat/FullMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TickMath} from "../../src/compat/TickMath.sol";

interface IUniswapV2Router01 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface IUniswapV2Pair{
    function totalSupply() external view returns (uint);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract UniswapV2Adapter is IVenueAdapter, Ownable {
    using SafeERC20 for IERC20;

    IUniswapV2Router01 public immutable router;
    IUniswapV2Pair public immutable pair;

    address public immutable token0;
    address public immutable token1;
    
    uint256 public constant EXPIRE_TIME = 300;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant slippageBps = 50;

    error ZeroAddress();
    error ZeroAmount();
    error ZeroBalance();

    constructor(address _router, address _pair, address _token0, address _token1) Ownable(msg.sender) {
        if(_router == address(0) || _pair == address(0)) revert ZeroAddress();
        router = IUniswapV2Router01(_router);
        token0 = _token0;
        token1 = _token1;
        pair = IUniswapV2Pair(_pair);
    } 

    function deposit(uint256 amount0, uint256 amount1, uint256 amount0Min, uint256 amount1Min) external override returns (uint256 amount0Used, uint256 amount1Used) {

        if(amount0 == 0 || amount1 == 0) revert ZeroAmount();

        IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);

        IERC20(token0).forceApprove(address(router), amount0);
        IERC20(token1).forceApprove(address(router), amount1);

        uint256 lpLiquidity;

        (amount0Used, amount1Used, lpLiquidity) = router.addLiquidity(
            token0,
            token1,
            amount0,
            amount1,
            amount0Min,
            amount1Min,
            address(this),
            block.timestamp + EXPIRE_TIME
        );

        IERC20(address(pair)).safeTransfer(msg.sender, lpLiquidity);

        IERC20(token0).forceApprove(address(router), 0);
        IERC20(token1).forceApprove(address(router), 0);

        emit DepositAdded(msg.sender, amount0Used, amount1Used, lpLiquidity);

    }

    function withdraw(uint256 shareRatio, uint256 minAmount0, uint256 minAmount1) external override returns (uint256 amount0Extracted, uint256 amount1Extracted) {
        if(shareRatio == 0) revert ZeroAmount();

        uint256 LPTotalSupply = pair.totalSupply();
        uint256 amountToWithdraw = FullMath.mulDiv(shareRatio, LPTotalSupply, PRECISION);

        IERC20(address(pair)).safeTransferFrom(msg.sender, address(this), amountToWithdraw);
        IERC20(address(pair)).forceApprove(address(router), amountToWithdraw);
        
        (amount0Extracted, amount1Extracted) = router.removeLiquidity(
            token0,
            token1,
            amountToWithdraw,
            minAmount0,
            minAmount1,
            address(this),
            block.timestamp + EXPIRE_TIME
        );

        IERC20(token0).safeTransfer(msg.sender, amount0Extracted);
        IERC20(token1).safeTransfer(msg.sender, amount1Extracted);

        IERC20(address(pair)).forceApprove(address(router), 0);

        emit withdrawDecreased(msg.sender, amount0Extracted, amount1Extracted);
        
    }
    
    function getPositionAmount0() external view override returns (uint256) {

        (uint112 reserve0, , ) = pair.getReserves();

        uint256 myLPBalance = IERC20(address(pair)).balanceOf(msg.sender);
        uint256 LPTotalSupply = pair.totalSupply();

        return _calculateShares(myLPBalance, uint256(reserve0), LPTotalSupply);
    }

    function getPositionAmount1() external view override returns (uint256) {
        ( , uint112 reserve1, ) = pair.getReserves();

        uint256 myLPBalance = IERC20(address(pair)).balanceOf(msg.sender);
        uint256 LPTotalSupply = pair.totalSupply();

        return _calculateShares(myLPBalance, uint256(reserve1), LPTotalSupply);
    }


    function swapTokens(uint256 amountIn, bool isZeroForOne, uint256 amountOutMin) external returns (uint256 amountOutActual) {
        address tokenIn;
        address tokenOut;

        if(isZeroForOne){
            tokenIn = token0;
            tokenOut = token1;
        }else{
            tokenIn = token1;
            tokenOut = token0;
        }

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            address(this),
            block.timestamp + EXPIRE_TIME
        );

        amountOutActual = amounts[amounts.length - 1];

        IERC20(tokenOut).safeTransfer(msg.sender, amountOutActual);
        IERC20(tokenIn).forceApprove(address(router), 0);

        emit TokensSwapped(msg.sender, tokenIn, tokenOut, amountIn, amountOutActual);

    }

    function getCurrentTick() external view override returns (int24) {
        uint256 price = _getCurrentPrice();
        uint256 priceX192 = FullMath.mulDiv(price, 1 << 192, PRECISION);
        uint160 sqrtPriceX96 = uint160(_sqrt(priceX192));
        return TickMath.getTickAtSqrtRatio(sqrtPriceX96);
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


    function getCurrentPrice() external view returns (uint256 price) {
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        if(reserve0 == 0 || reserve1 == 0) revert ZeroAmount();
        price = FullMath.mulDiv(reserve1, PRECISION, reserve0);
    }

    function _getCurrentPrice() internal view returns (uint256 price) {
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        if(reserve0 == 0 || reserve1 == 0) revert ZeroAmount();
        price = FullMath.mulDiv(reserve1, PRECISION, reserve0);
    }

    /**
     * @notice Calculate the ratio: Calculate the number of shares corresponding to a certain amount of assets.
     * @dev Formula: shares = (amount * totalSupply) / totalAssets
     * @param amount The amount of assets for which the share is to be calculated.
     * @param totalSupply The total supply of vouchers.
     * @param totalAssets The total amount of assets.
     * @return shares The number of vouchers corresponding to the given amount of assets.
     */
    function _calculateShares(
        uint256 amount,
        uint256 totalSupply,
        uint256 totalAssets
    ) internal pure returns (uint256 shares){
        if(totalAssets == 0 || totalSupply == 0) revert ZeroAmount();
        shares = FullMath.mulDiv(amount, totalSupply, totalAssets);
    }

    function _getBalance(address token) internal view returns (uint256 balance) {
        balance = IERC20(token).balanceOf(address(this));
    }

    function rescueToken(address token) external onlyOwner {
        uint256 balance = _getBalance(token);
        if(balance == 0) revert ZeroBalance();
        IERC20(token).safeTransfer(msg.sender, balance);
    }

}