//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol"; 
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UniswapV2Adapter} from "../src/adapters/UniswapV2Adapter.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {IVenueAdapter} from "../src/interface/IVenueAdapter.sol";
import {FullMath} from "../src/compat/FullMath.sol";
import {TickMath} from "../src/compat/TickMath.sol";
import {TWAPOracle} from "../src/TWAPOracle.sol";



contract AdaptiveIPVault is ERC20,Ownable,Pausable,ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct CooldownTier {
        uint24 tickDeltaThreshold;
        uint32 cooldownSeconds;
    }

    CooldownTier[] public cooldownTiers;

    address public immutable token0;
    address public immutable token1;

    IVenueAdapter public venueAdapter;
    TWAPOracle public immutable oracle;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant slippageBps = 50;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant POST_EXECUTION_GAS_BASELINE = 26000;
    uint256 public premiumMultiplierBps;
    uint256 public maxRewardLimit;
    uint256 public lastRebalanceTimestamp;

    uint256 public constant PANIC_TICK_THRESHOLD = 1000;
    uint32 public constant MIN_COOLDOWN_LIMIT = 300;
    uint32 public baseMinCooldown = 3600;

    bool public immutable isToken0Base;
    
    error ZeroAmount();
    error ZeroAddress();
    error InvalidAmount();
    error InvalidCooldownSeconds();
    error NotReadyToRebalance();

    event VaultDeposit(address indexed sender, uint256 amount0, uint256 amount1, uint256 shares);
    event VaultWithdraw(address indexed sender, uint256 amount0, uint256 amount1, uint256 shares);
    event RebalancePerformed(address indexed sender, uint256 amount0Extracted, uint256 amount1Extracted, uint256 amount0Used, uint256 amount1Used);
    event VenueAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event KeeperRewarded(address indexed keeper, uint256 rewardAmount, uint256 totalGasUsed);

    constructor (
        string memory tokenName, 
        string memory tokenSign, 
        address _token0, 
        address _token1, 
        address _adapter, 
        address _oracle, 
        address _vaultBaseToken,
        uint256 _premiumMultiplierBps,
        uint256 _maxRewardLimit
    )
        ERC20(tokenName,tokenSign)
        Ownable(msg.sender){
            if(_token0 == address(0) || _token1 == address(0) || _adapter == address(0)) revert ZeroAddress();
            venueAdapter = IVenueAdapter(_adapter);
            token0 = _token0;
            token1 = _token1;
            oracle = TWAPOracle(_oracle);

            isToken0Base = (_token0 == _vaultBaseToken);

            if(_premiumMultiplierBps < BPS_DENOMINATOR) revert InvalidAmount();
            if(_maxRewardLimit == 0) revert ZeroAmount();

            premiumMultiplierBps = _premiumMultiplierBps;
            maxRewardLimit = _maxRewardLimit;

            cooldownTiers.push(CooldownTier({tickDeltaThreshold: 100, cooldownSeconds: 1800}));
            cooldownTiers.push(CooldownTier({tickDeltaThreshold: 300, cooldownSeconds: 600}));
            cooldownTiers.push(CooldownTier({tickDeltaThreshold: 500, cooldownSeconds: 300}));
    }

    function setBountyConfig(uint256 _premium, uint256 _maxLimit) external onlyOwner {
        if(_premium < BPS_DENOMINATOR) revert InvalidAmount();
        if(_maxLimit == 0) revert ZeroAmount();

        premiumMultiplierBps = _premium;
        maxRewardLimit = _maxLimit;
    }

    function setCooldownTiers(CooldownTier[] calldata _newTier) external onlyOwner {
        delete cooldownTiers;
        for (uint256 i = 0; i < _newTier.length; i++) {
            if(_newTier[i].cooldownSeconds < MIN_COOLDOWN_LIMIT) revert InvalidCooldownSeconds();
            cooldownTiers.push(_newTier[i]);
        }
    }

    function deposit(uint256 amount0, uint256 amount1, uint256 amount0Min, uint256 amount1Min) external nonReentrant whenNotPaused  {
        if(amount0 == 0 || amount1 == 0) revert ZeroAmount();

        uint256 reserve0 = venueAdapter.getPositionAmount0();
        uint256 reserve1 = venueAdapter.getPositionAmount1();
        uint256 totalSupply = totalSupply();
        uint256 totalAssets;
        uint256 amount;

        if(totalSupply != 0) {
            uint256 amount1Required = _getEquivalentAmount(amount0, reserve0, reserve1);
            if(amount1 != amount1Required) revert InvalidAmount();

            uint256 value0;
            uint256 value1;
            uint256 price = venueAdapter.getCurrentPrice();
            if(isToken0Base) {
                value0 = reserve0;
                value1 = FullMath.mulDiv(reserve1, PRECISION, price);
            }else{
                value0 = FullMath.mulDiv(reserve0, price, PRECISION);
                value1 = reserve1;
            }

            totalAssets = value0 + value1;

            uint256 amount0InAmount1 = FullMath.mulDiv(amount0, price, PRECISION);
            amount = amount0InAmount1 + amount1;

        }else{
            amount = amount0 + amount1;
        }

        IERC20(token0).safeTransferFrom(msg.sender,address(this),amount0);
        IERC20(token1).safeTransferFrom(msg.sender,address(this),amount1);

        IERC20(token0).forceApprove(address(venueAdapter), amount0);
        IERC20(token1).forceApprove(address(venueAdapter), amount1);
        
        venueAdapter.deposit(amount0, amount1, amount0Min, amount1Min);

        uint256 shares;
        if(totalSupply == 0){
            shares = amount;
        }else{
            shares = _calculateShares(amount, totalSupply, totalAssets);
        }

        _mint(msg.sender, shares);

        IERC20(token0).forceApprove(address(venueAdapter), 0);
        IERC20(token1).forceApprove(address(venueAdapter), 0);

        emit VaultDeposit(msg.sender, amount0, amount1, shares);
    }

    function withdraw(uint256 shares, uint256 minAmount0, uint256 minAmount1) external nonReentrant whenNotPaused {
        if(shares == 0) revert ZeroAmount();

        uint256 totalSupply = totalSupply();

        uint256 shareRatio = FullMath.mulDiv(shares, PRECISION, totalSupply);

        _burn(msg.sender, shares);

        (uint256 amount0, uint256 amount1) = venueAdapter.withdraw(shareRatio, minAmount0, minAmount1);
        IERC20(token0).safeTransfer(msg.sender, amount0);
        IERC20(token1).safeTransfer(msg.sender, amount1);

        emit VaultWithdraw(msg.sender, amount0, amount1, shares);
    }

    function rebalance() external nonReentrant whenNotPaused {
        uint256 startGas = gasleft();

        _executeRebalance();

        _payKeeperReward(startGas);

    }

    function _executeRebalance() internal {

        if(!_shouldRebalance()) revert NotReadyToRebalance();

        bool isZeroForOne;

        uint256 reserve0 = venueAdapter.getPositionAmount0();
        uint256 reserve1 = venueAdapter.getPositionAmount1();

        uint256 price = venueAdapter.getCurrentPrice();
        int24 fastTwapTick = oracle.getFastTwapTick();

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(fastTwapTick);

        uint256 value0;
        uint256 value1;

        if(isToken0Base) {
            value0 = reserve0;
            value1 = FullMath.mulDiv(reserve1, PRECISION, price);
        }else{
            value0 = FullMath.mulDiv(reserve0, price, PRECISION);
            value1 = reserve1;
        }

        uint256 excessValue;
        uint256 amountToSwap;
        uint256 expectedOut;
        uint256 twapPrice = FullMath.mulDiv(uint256(sqrtPriceX96) * PRECISION, sqrtPriceX96, 1 << 192);

        (uint256 amount0Extracted, uint256 amount1Extracted) = venueAdapter.withdraw(PRECISION, 0, 0);

        if(value0 > value1){
            isZeroForOne = true;
            excessValue = value0 - value1;//谁是本位币，这里就用谁计价的
            amountToSwap = isToken0Base
                ? excessValue / 2
                : FullMath.mulDiv(excessValue / 2, PRECISION, price);
        } else if(value1 > value0){
            isZeroForOne = false;
            excessValue = value1 - value0;
            amountToSwap = isToken0Base
                ? FullMath.mulDiv(excessValue / 2, price, PRECISION)
                : excessValue / 2;
        }

        if (amountToSwap > 0) {
            if (isZeroForOne) {
                expectedOut = isToken0Base 
                    ? FullMath.mulDiv(amountToSwap, twapPrice, PRECISION)
                    : FullMath.mulDiv(amountToSwap, PRECISION, twapPrice);
            } else {
                expectedOut = isToken0Base 
                    ? FullMath.mulDiv(amountToSwap, PRECISION, twapPrice)
                    : FullMath.mulDiv(amountToSwap, twapPrice, PRECISION);
            }
        }
        uint256 amountOutMin = FullMath.mulDiv(expectedOut, BPS_DENOMINATOR-slippageBps, BPS_DENOMINATOR);
        venueAdapter.swapTokens(amountToSwap, isZeroForOne, amountOutMin);

        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0Min;
        uint256 amount1Min;

        uint256 amount0Required = _getEquivalentAmount(bal1 , reserve0, reserve1);
        uint256 amount1Required = _getEquivalentAmount(bal0 , reserve1, reserve0);

        if(amount1Required <= bal1){
            amount0Min = FullMath.mulDiv(bal0, BPS_DENOMINATOR-slippageBps, BPS_DENOMINATOR);
            amount1Min = FullMath.mulDiv(amount1Required, BPS_DENOMINATOR-slippageBps, BPS_DENOMINATOR);
        }else{
            amount0Min = FullMath.mulDiv(amount0Required, BPS_DENOMINATOR-slippageBps, BPS_DENOMINATOR);
            amount1Min = FullMath.mulDiv(bal1, BPS_DENOMINATOR-slippageBps, BPS_DENOMINATOR);
        }

        IERC20(token0).forceApprove(address(venueAdapter), bal0);
        IERC20(token1).forceApprove(address(venueAdapter), bal1);

        (uint256 amount0Used, uint256 amount1Used) = venueAdapter.deposit(bal0, bal1, amount0Min, amount1Min);

        lastRebalanceTimestamp = uint32(block.timestamp);

        emit RebalancePerformed(msg.sender, amount0Extracted, amount1Extracted, amount0Used, amount1Used);
        
    }

    function _payKeeperReward(uint256 startGas) internal {
        uint256 totalGasUsed = startGas - gasleft() + POST_EXECUTION_GAS_BASELINE ;

        uint256 baseGasCost = totalGasUsed * tx.gasprice;

        uint256 keeperRewardAmount = FullMath.mulDiv(baseGasCost, premiumMultiplierBps, BPS_DENOMINATOR);

        if(keeperRewardAmount > maxRewardLimit){
            keeperRewardAmount = maxRewardLimit;
        }

        uint256 vaultBal;

        if(isToken0Base){
            vaultBal = IERC20(token0).balanceOf(address(this));
            if(keeperRewardAmount > vaultBal) {
                keeperRewardAmount = vaultBal;
            }
            if(vaultBal > 0){
                IERC20(token0).safeTransfer(msg.sender, keeperRewardAmount);
            }
        }else{
            vaultBal = IERC20(token1).balanceOf(address(this));
            if(keeperRewardAmount > vaultBal) {
                keeperRewardAmount = vaultBal;
            }
            if(vaultBal > 0){
                IERC20(token1).safeTransfer(msg.sender, keeperRewardAmount);
            }
        }

        emit KeeperRewarded(msg.sender, keeperRewardAmount, baseGasCost);
    }

    function _shouldRebalance() internal view returns (bool) {

        int24 fastTwapTick = oracle.getFastTwapTick();
        int24 slowTwapTick = oracle.getTwapTick();

        uint24 realMarketDeviation = fastTwapTick > slowTwapTick
            ? uint24(fastTwapTick - slowTwapTick)
            : uint24(slowTwapTick - fastTwapTick);
        
        if(realMarketDeviation >= PANIC_TICK_THRESHOLD) return true;

        uint32 dynamicCooldown = _getDynamicCooldown();

        if(block.timestamp < lastRebalanceTimestamp + dynamicCooldown) {
            return false;
        }
        return true;
    }

    function _getDynamicCooldown() internal view returns (uint32) {
        
        uint24 tickDelta = _getCurrentTickDelta();

        if(tickDelta == 0 || tickDelta < cooldownTiers[0].tickDeltaThreshold){
            return baseMinCooldown;
        }

        //Scan from the back to the front and check the most serious situations first.
        for (uint256 i = cooldownTiers.length; i > 0; i--) {
            CooldownTier memory tier = cooldownTiers[i - 1];
            if(tier.tickDeltaThreshold <= tickDelta) {
                return tier.cooldownSeconds;
            }
        }

        return baseMinCooldown;
    }

    function _getCurrentTickDelta() internal view returns (uint24 tickDelta) {
        int24 tick = oracle.getTwapTick();
        int24 currentTick = venueAdapter.getCurrentTick();
        tickDelta = (currentTick > tick ? uint24(currentTick - tick) : uint24(tick - currentTick));
    }

    function setVenueAdapter(address newAdapter) external onlyOwner {
        if(newAdapter == address(0)) revert ZeroAddress();
        address oldAdapter = address(venueAdapter);
        venueAdapter = IVenueAdapter(newAdapter);
        emit VenueAdapterUpdated(oldAdapter, newAdapter);
    }

    function _getEquivalentAmount(
        uint256 amount0,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (uint256 amount1Required){
        if(reserve0 == 0) revert ZeroAmount();
        amount1Required = FullMath.mulDiv(amount0, reserve1, reserve0);
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

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}