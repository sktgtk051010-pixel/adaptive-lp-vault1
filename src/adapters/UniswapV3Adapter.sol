//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol"; 
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVenueAdapter} from "../interface/IVenueAdapter.sol";
import {TickMath} from "../compat/TickMath.sol";
import {FullMath} from "../compat/FullMath.sol";
import {LiquidityAmounts} from "../compat/LiquidityAmounts.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "forge-std/console.sol";

interface INonfungiblePositionManager
{
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }


    function mint(MintParams calldata params)
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }


    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    
}


contract UniswapV3Adapter is IVenueAdapter,Ownable {
    using SafeERC20 for IERC20;

    uint256 public tokenId;
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Pool public immutable pool;
    ISwapRouter public immutable router;
    uint256 public constant EXPIRE_TIME = 300;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant slippageBps = 50;
    int24 public myTickLower;
    int24 public myTickUpper;
    
    error ZeroAddress();
    error ZeroAmount();
    error ZeroBalance();
    error ZeroRemaining();
    error InvalidTickLower();

    constructor( address _positionManager, address _pool, address _router) Ownable(msg.sender) {
        if(_positionManager == address(0) || _pool == address(0) || _router == address(0)) revert ZeroAddress();
        positionManager = INonfungiblePositionManager(_positionManager);
        pool = IUniswapV3Pool(_pool);
        router = ISwapRouter(_router);
    }

    function setStrategy(int24 _tickLower, int24 _tickUpper) external onlyOwner {
        if(_tickLower > _tickUpper) revert InvalidTickLower();
        myTickLower = _tickLower;
        myTickUpper = _tickUpper;
    }

    function deposit(uint256 amount0, uint256 amount1, uint256 amount0Min, uint256 amount1Min) external returns (uint256 amount0Used, uint256 amount1Used) {

        address token0;
        address token1;

        console.log("Pool Code Length: ", address(pool).code.length);
        require(address(pool).code.length > 0, "Address has no code!"); 

        if (tokenId == 0) {
            console.log("Current Pool Address: ", address(pool)); 
            require(address(pool) != address(0), "Pool address is zero!");
            token0 = pool.token0();
            token1 = pool.token1();
        } else {
            (,, token0, token1,,, , , , , , ) = positionManager.positions(tokenId);
        }

        IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);

        IERC20(token0).forceApprove(address(positionManager), amount0);
        IERC20(token1).forceApprove(address(positionManager), amount1);

        uint128 addedLiquidity;

        if(tokenId == 0){
            INonfungiblePositionManager.MintParams memory mintParams = 
            INonfungiblePositionManager.MintParams ({
                token0 : pool.token0(),
                token1 : pool.token1(),
                fee : pool.fee(),
                tickLower : myTickLower,
                tickUpper : myTickUpper,
                amount0Desired : amount0,
                amount1Desired : amount1,
                amount0Min : amount0Min,
                amount1Min : amount1Min,
                recipient : address(this),
                deadline : block.timestamp + EXPIRE_TIME
            });
            (tokenId, addedLiquidity, amount0Used, amount1Used) = positionManager.mint(mintParams);

        }else{

            INonfungiblePositionManager.IncreaseLiquidityParams memory increaseLiquidityParams = 
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId : tokenId,
                amount0Desired : amount0,
                amount1Desired : amount1,
                amount0Min : amount0Min,
                amount1Min : amount1Min,
                deadline : block.timestamp + EXPIRE_TIME
            });
            (
            addedLiquidity,
            amount0Used,
            amount1Used
        ) = positionManager.increaseLiquidity(increaseLiquidityParams);
    }

    uint256 remaining0 = _getBalance(token0);
    uint256 remaining1 = _getBalance(token1);

    if(remaining0 == 0 || remaining1 == 0) revert ZeroRemaining();

    IERC20(token0).safeTransfer(msg.sender, remaining0);
    IERC20(token1).safeTransfer(msg.sender, remaining1);

    IERC20(token0).forceApprove(address(positionManager), 0);
    IERC20(token1).forceApprove(address(positionManager), 0);
    
    emit DepositAdded(msg.sender, amount0Used, amount1Used, addedLiquidity);
    
    }
    

    function withdraw(uint256 shareRatio, uint256 minAmount0, uint256 minAmount1) external returns (uint256 amount0Extracted, uint256 amount1Extracted) {
        if(shareRatio == 0) revert ZeroAmount();

        (
             ,
             ,
             ,
             ,
             ,
             ,
             ,
            uint128 liquidity,
             ,
             ,
             ,
            
        ) = positionManager.positions(tokenId);

        uint256 amountToWithdraw = FullMath.mulDiv(shareRatio, uint256(liquidity), PRECISION);

        (
             ,
             ,
            address token0,
            address token1,
             ,
             ,
             ,
             ,
             ,
             ,
             ,
            
        ) = positionManager.positions(tokenId);

        INonfungiblePositionManager.CollectParams memory collectParams = 
        INonfungiblePositionManager.CollectParams ({
        tokenId : tokenId,
        recipient : address(this),
        amount0Max : type(uint128).max,
        amount1Max : type(uint128).max
    });
    (uint256 feeAmount0, uint256 feeAmount1) = positionManager.collect(collectParams);

    INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseLiquidityParams = 
    INonfungiblePositionManager.DecreaseLiquidityParams ({
        tokenId : tokenId,
        liquidity : uint128(amountToWithdraw),
        amount0Min : minAmount0,
        amount1Min : minAmount1,
        deadline : block.timestamp + EXPIRE_TIME
    });
    (uint256 amount0, uint256 amount1) = positionManager.decreaseLiquidity(decreaseLiquidityParams);

    amount0Extracted = amount0 + feeAmount0;
    amount1Extracted = amount1 + feeAmount1;

    IERC20(token0).safeTransfer(msg.sender, amount0Extracted);
    IERC20(token1).safeTransfer(msg.sender, amount1Extracted);

    // forge-lint: disable-next-line(unsafe-typecast)
    emit withdrawDecreased(msg.sender, amount0Extracted, amount1Extracted);

    }

    function getPositionAmount0() external view override returns (uint256) {

        if (tokenId == 0) return 0;

        (
             ,
             ,
             ,
             ,
             ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
             ,
             ,
            uint128 tokensOwed0,
            
        ) = positionManager.positions(tokenId);

        (
            uint160 sqrtPriceX96,
             ,
             ,
             ,
             ,
             ,
            
        ) = pool.slot0();

        (uint256 amount0, ) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity);

        return (amount0 + uint256(tokensOwed0));
    }

    function getPositionAmount1() external view override returns (uint256) {

        if (tokenId == 0) return 0;

        (
             ,
             ,
             ,
             ,
             ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
             ,
             ,
            uint128 tokensOwed1,
            
        ) = positionManager.positions(tokenId);

        (
            uint160 sqrtPriceX96,
             ,
             ,
             ,
             ,
             ,
            
        ) = pool.slot0();

        (uint256 amount1, ) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity);

        return (amount1 + uint256(tokensOwed1));

    }

    function getCurrentTick() external view override returns (int24) {
        (
             ,
            int24 tick,
             ,
             ,
             ,
             ,
            
        ) =  pool.slot0();

        return tick;
    }

    function getCurrentPrice() external view returns (uint256 price) {
        (
            uint160 sqrtPriceX96,
             ,
             ,
             ,
             ,
             ,
            
        ) =  pool.slot0();
        price = FullMath.mulDiv(uint256(sqrtPriceX96) * PRECISION, sqrtPriceX96, 1 << 192);
    }

    function swapTokens(uint256 amountIn, bool isZeroForOne, uint256 amountOutMin) external returns (uint256 amountOutActual) {

        (
             ,
             ,
            address token0,
            address token1,
            uint24 fee,
             ,
             ,
             ,
             ,
             ,
             ,
            
        ) = positionManager.positions(tokenId);

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

        ISwapRouter.ExactInputSingleParams memory exactInputSingleParams = ISwapRouter.ExactInputSingleParams({
            tokenIn : tokenIn,
            tokenOut : tokenOut,
            fee : fee,
            recipient : address(this),
            deadline : block.timestamp + EXPIRE_TIME,
            amountIn : amountIn,
            amountOutMinimum : amountOutMin,
            sqrtPriceLimitX96 : 0
        });

        amountOutActual = router.exactInputSingle(exactInputSingleParams);

        IERC20(tokenOut).safeTransfer(msg.sender, amountOutActual);
        IERC20(tokenIn).forceApprove(address(router), 0);

        emit TokensSwapped(msg.sender, tokenIn, tokenOut, amountIn, amountOutActual);
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

    function _getBalance(address token) internal view returns (uint256 balance) {
        balance = IERC20(token).balanceOf(address(this));
    }

    function rescueToken(address token) external onlyOwner {
        uint256 balance = _getBalance(token);
        if(balance == 0) revert ZeroBalance();
        IERC20(token).safeTransfer(msg.sender, balance);
    }
    
}

