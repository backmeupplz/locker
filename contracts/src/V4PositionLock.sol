// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IPositionManager {
    function ownerOf(uint256 tokenId) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

/// @title V4PositionLock
/// @notice Holds Uniswap v4 position NFTs until `unlockAt`. No owner, no rescue, no early release.
///         Anyone may collect a locked position's fees; they always go to the immutable beneficiary.
///         After `unlockAt`, anyone may call `approveBeneficiary`, which gives the beneficiary operator
///         approval over every position held here. Lock a position with a plain
///         `PositionManager.transferFrom(owner, lock, tokenId)` (there is no onERC721Received, so
///         safeTransferFrom reverts).
/// @dev Same logic as VeydriftV4PositionLock in Borodutch/veydrift (packages/contracts/src/VeydriftUniswapLaunch.sol).
contract V4PositionLock {
    uint8 private constant ACTION_DECREASE_LIQUIDITY = 0x01;
    uint8 private constant ACTION_TAKE_PAIR = 0x11;

    address public immutable positionManager;
    address public immutable beneficiary;
    uint64 public immutable unlockAt;

    error InvalidPositionManager();
    error InvalidBeneficiary();
    error InvalidUnlockTime();
    error PositionLockActive(uint64 unlockAt);
    error PositionNotLocked(uint256 tokenId, address actualOwner);

    event BeneficiaryApproved(address indexed beneficiary, uint64 indexed unlockAt);
    event FeesCollected(uint256 indexed tokenId, address indexed beneficiary);

    constructor(address positionManager_, address beneficiary_, uint64 unlockAt_) {
        if (positionManager_.code.length == 0) revert InvalidPositionManager();
        if (beneficiary_ == address(0)) revert InvalidBeneficiary();
        if (unlockAt_ <= block.timestamp) revert InvalidUnlockTime();
        positionManager = positionManager_;
        beneficiary = beneficiary_;
        unlockAt = unlockAt_;
    }

    function approveBeneficiary() external {
        if (block.timestamp < unlockAt) revert PositionLockActive(unlockAt);
        IPositionManager(positionManager).setApprovalForAll(beneficiary, true);
        emit BeneficiaryApproved(beneficiary, unlockAt);
    }

    /// @notice Collects only the accrued fees of a position held by this lock and sends them to the beneficiary.
    /// @dev A zero-liquidity decrease realizes fees without touching principal liquidity.
    function collectFees(uint256 tokenId) external {
        IPositionManager manager = IPositionManager(positionManager);
        address actualOwner = manager.ownerOf(tokenId);
        if (actualOwner != address(this)) revert PositionNotLocked(tokenId, actualOwner);

        (PoolKey memory key,) = manager.getPoolAndPositionInfo(tokenId);
        bytes memory actions = abi.encodePacked(ACTION_DECREASE_LIQUIDITY, ACTION_TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, beneficiary);
        manager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        emit FeesCollected(tokenId, beneficiary);
    }
}
