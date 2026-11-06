// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {V4PositionLock, PoolKey} from "../src/V4PositionLock.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IPM {
    function ownerOf(uint256) external view returns (address);
    function transferFrom(address, address, uint256) external;
    function safeTransferFrom(address, address, uint256) external;
    function getPositionLiquidity(uint256) external view returns (uint128);
    function getPoolAndPositionInfo(uint256) external view returns (PoolKey memory, uint256);
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata) external returns (bytes memory);
    function swap(PoolKey memory, SwapParams memory, bytes calldata) external returns (int256);
    function sync(address) external;
    function settle() external payable returns (uint256);
    function take(address, address, uint256) external;
}

/// Swaps currency1 -> currency0 exact-in through the PoolManager, so the pool earns fees.
contract Swapper {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    function swap1For0(PoolKey memory key, uint256 amountIn) external {
        POOL_MANAGER.unlock(abi.encode(key, amountIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 amountIn) = abi.decode(data, (PoolKey, uint256));
        int256 delta = POOL_MANAGER.swap(
            key, SwapParams(false, -int256(amountIn), 1461446703485210103287273052203988822378723970341), ""
        );
        int128 out0 = int128(delta >> 128);
        int128 in1 = int128(delta);
        POOL_MANAGER.sync(key.currency1);
        IERC20(key.currency1).transfer(address(POOL_MANAGER), uint256(uint128(-in1)));
        POOL_MANAGER.settle();
        POOL_MANAGER.take(key.currency0, address(this), uint256(uint128(out0)));
        return "";
    }
}

/// Base fork test against the real VEYDRIFT resource pools (`plain test --fork base`).
contract V4PositionLockForkTest is Test {
    IPM constant PM = IPM(0x7C5f5A4bBd8fD63184577525326123B519429bDc);
    address constant BORODUTCH = 0xbf74483DB914192bb0a9577f3d8Fb29a6d4c08eE;
    address constant VEYDRIFT = 0x442E9Ba64899d6B0bD25DF2558d3E804427bF448;
    uint256 constant METAL_POSITION = 3204056; // vMETAL/VEYDRIFT, 0.9%
    uint256[3] ids = [uint256(3204056), 3204065, 3204067];

    V4PositionLock lock;

    function setUp() public {
        if (block.chainid != 8453) vm.skip(true);
        lock = new V4PositionLock(address(PM), BORODUTCH, uint64(block.timestamp + 365 days));
        vm.startPrank(BORODUTCH);
        for (uint256 i; i < ids.length; i++) PM.transferFrom(BORODUTCH, address(lock), ids[i]);
        vm.stopPrank();
    }

    function test_locksAndCollectsFeesToBeneficiary() public {
        for (uint256 i; i < ids.length; i++) assertEq(PM.ownerOf(ids[i]), address(lock));

        (PoolKey memory key,) = PM.getPoolAndPositionInfo(METAL_POSITION);
        uint128 liquidity = PM.getPositionLiquidity(METAL_POSITION);
        Swapper swapper = new Swapper();
        vm.prank(BORODUTCH);
        IERC20(VEYDRIFT).transfer(address(swapper), 1_000_000 ether);
        swapper.swap1For0(key, 1_000_000 ether);

        uint256 before = IERC20(VEYDRIFT).balanceOf(BORODUTCH);
        vm.prank(address(0xBEEF)); // anyone can trigger; fees still go to the beneficiary
        lock.collectFees(METAL_POSITION);
        uint256 fees = IERC20(VEYDRIFT).balanceOf(BORODUTCH) - before;
        assertApproxEqRel(fees, 9_000 ether, 0.001e18); // 0.9% of 1M, the position is the whole pool
        assertEq(PM.getPositionLiquidity(METAL_POSITION), liquidity);
        assertEq(PM.ownerOf(METAL_POSITION), address(lock));

        for (uint256 i; i < ids.length; i++) lock.collectFees(ids[i]); // no fees accrued: still fine
    }

    function test_releasesOnlyAfterUnlock() public {
        vm.expectRevert(abi.encodeWithSelector(V4PositionLock.PositionLockActive.selector, lock.unlockAt()));
        lock.approveBeneficiary();
        vm.prank(BORODUTCH);
        vm.expectRevert();
        PM.transferFrom(address(lock), BORODUTCH, METAL_POSITION);

        vm.warp(lock.unlockAt());
        lock.approveBeneficiary();
        vm.prank(BORODUTCH);
        PM.transferFrom(address(lock), BORODUTCH, METAL_POSITION);
        assertEq(PM.ownerOf(METAL_POSITION), BORODUTCH);
    }

    function test_rejectsPositionsItDoesNotHold() public {
        address owner = PM.ownerOf(1);
        vm.expectRevert(abi.encodeWithSelector(V4PositionLock.PositionNotLocked.selector, 1, owner));
        lock.collectFees(1);
    }

    function test_safeTransferIsRejected() public {
        vm.warp(lock.unlockAt());
        lock.approveBeneficiary();
        vm.prank(BORODUTCH);
        PM.transferFrom(address(lock), BORODUTCH, METAL_POSITION);
        vm.prank(BORODUTCH);
        vm.expectRevert();
        PM.safeTransferFrom(BORODUTCH, address(lock), METAL_POSITION);
    }
}
