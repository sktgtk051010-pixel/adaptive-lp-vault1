// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function approve(address, uint256) external returns (bool) { return true; }
    function forceApprove(address, uint256) external {}
}

contract MockVenueAdapter {
    uint256 public lastSwapAmount;
    bool public lastIsZeroForOne;
    uint256 public mockAmount0 = 1000e18;
    uint256 public mockAmount1 = 1000e18;
    bool public shouldRevertWithdraw;

    function setMockBalances(uint256 a0, uint256 a1) external {
        mockAmount0 = a0;
        mockAmount1 = a1;
    }

    function setShouldRevertWithdraw(bool value) external {
        shouldRevertWithdraw = value;
    }

    function getPositionAmount0() external view virtual returns (uint256) { return mockAmount0; }
    function getPositionAmount1() external view virtual returns (uint256) { return mockAmount1; }
    function getCurrentPrice() external view virtual returns (uint256) { return 1e18; }
    function deposit(uint256, uint256, uint256, uint256) external virtual returns (uint256, uint256) { return (100e18, 100e18); }
    function withdraw(uint256, uint256, uint256) external virtual returns (uint256, uint256) { 
        if (shouldRevertWithdraw) revert("withdraw reverted");
        return (10e18, 10e18); 
    }
    function getCurrentTick() external view virtual returns (int24) { return 0; }
    
    function swapTokens(uint256 amount, bool isZeroForOne, uint256) external virtual returns (uint256) {
        lastSwapAmount = amount;
        lastIsZeroForOne = isZeroForOne;
        return amount;
    }
}

contract MockOracle {
    int24 public mockFastTick;
    int24 public mockSlowTick;

    function setTicks(int24 fast, int24 slow) external {
        mockFastTick = fast;
        mockSlowTick = slow;
    }

    function getTwapTick() external view virtual returns (int24) { return mockSlowTick; }
    function getFastTwapTick() external view virtual returns (int24) { return mockFastTick; }
}