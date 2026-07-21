//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVenueAdapter{

    event DepositAdded(address indexed caller, uint256 amount0Used, uint256 amount1Used, uint256 liquidity);
    event withdrawDecreased(address indexed caller, uint256 amount0Extracted, uint256 amount1Extracted);
    event TokensSwapped(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut, 
        uint256 amountIn,
        uint256 amountOutActual
    );
    
    function deposit(
        uint256 amount0, 
        uint256 amount1, 
        uint256 amount0Min, 
        uint256 amount1Min)
        external returns (uint256 amount0Used, uint256 amount1Used);
    function withdraw(
        uint256 shareRatio, 
        uint256 minAmount0, 
        uint256 minAmount1)
         external returns (uint256 amount0Extracted, uint256 amount1Extracted);
    function getPositionAmount0() external view returns (uint256);
    function getPositionAmount1() external view returns (uint256);
    function getCurrentTick() external view returns (int24);
    function getCurrentPrice() external view returns (uint256 price);
    function swapTokens(
        uint256 amountIn, 
        bool isZeroForOne, 
        uint256 amountOutMin) external returns (uint256 amountOutActual);
}