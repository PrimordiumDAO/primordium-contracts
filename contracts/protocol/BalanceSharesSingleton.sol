// SPDX-License-Identifier: MIT
// Primordium Contracts

pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BasisPoints} from "contracts/libraries/BasisPoints.sol";
import {IArrayLengthErrors} from "contracts/interfaces/IArrayLengthErrors.sol";
import {IBalanceSharesManager} from "contracts/executor/interfaces/IBalanceSharesManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title A singleton contract for clients to manage account shares (in basis points) for ETH/ERC20 assets.
 *
 * @author Ben Jett - @BCJdevelopment
 *
 * @dev This singleton allows any client to create balance shares with one or more account shares for each balance
 * share. Each account share is denoted in basis points.
 *
 * The main point of this singleton is to significantly reduce gas costs for a protocol's users by releasing assets to
 * account share recipients in batch withdrawals. A client only needs to specify a balance share ID, for which they can
 * setup any account shares they choose, and add balances to the balance share to be withdrawn by the individual account
 * share recipients at any point in time.
 *
 * The internal accounting of this contract also allows a client to make updates to a balance share (such as
 * adding/removing account shares, updating the BPS for an account, etc.) at any point in time, and account recipients
 * will still be able to withdraw their pro rata claim to the accumulated balance share assets at any point in time.
 *
 * A hypothetical example: 4 accounts need to each receive 5% of the deposit amount for an on-chain mint. Rather than
 * paying huge gas costs to send 5% of the deposit amount to 4 different accounts every time asset(s) are minted, the
 * minting contract creates a new balance share ID for deposits, adds the 4 accounts with 5% each, and then sends 20% of
 * the deposit amount for each mint transaction to this contract. Then, each individual account recipient can process a
 * batch withdrawal of their claim to the accumulated balance share assets at any point in time.
 *
 * Account share recipients can also give permissions to other accounts (or open permissions to any account) to process
 * withdrawals on their behalf (still sending the assets to their own account).
 *
 * As a final dev note, this contract uses mappings instead of arrays to store checkpoints, because the author of this
 * contract has storage collision paranoia. There are gas optimized function helpers to access some of these mapping
 * values, but changing the ordering of any of the mappings in storage will result in errors with these functions.
 */
contract BalanceSharesSingleton is IBalanceSharesManager {
    using BasisPoints for uint256;

    mapping(address client => mapping(uint256 balanceShareId => BalanceShare)) private _balanceShares;

    /**
     * @dev IMPORTANT: Changing the order of variables in this struct could affect the optimized mapping retrieval
     * functions at the bottom of the file.
     */
    struct BalanceShare {
        // New balance sum checkpoint created every time totalBps changes, or when asset sum overflow occurs
        // Mapping, not array, to avoid storage collisions
        uint256 balanceSumCheckpointIndex;
        mapping(uint256 balanceSumIndex => BalanceSumCheckpoint) balanceSumCheckpoints;

        mapping(address => AccountShare) accounts;

        // TODO: Client approval of account withdrawal per balance share
    }

    /**
     * @dev IMPORTANT: Changing the order of variables in this struct could affect the optimized mapping retrieval
     * functions at the bottom of the file.
     */
    struct BalanceSumCheckpoint {
        uint256 totalBps; // Tracks the totalBps among all account shares for this balance sum checkpoint
        mapping(address asset => BalanceSum) balanceSums;
    }

    /**
     * @dev Storing asset remainders in the BalanceSum struct will not carry asset remainders over to a new
     * BalanceSumCheckpoint, but packing the storage with the asset balance avoids writing to an extra storage slot
     * when a new balance is processed and added to the balance sum. We optimize for the gas usage here, as new
     * checkpoints will only be written when the total BPS changes or an asset overflows, both of which are not likely
     * to be as common of events as the actual balance processing itself.
     */
    struct BalanceSum {
        uint48 remainder;
        uint208 balance;
    }

    struct AccountShare {
        // Store each account share period for the account, sequentially
        // Mapping, not array, to avoid storage collisions
        uint256 periodIndex;
        mapping(uint256 checkpointIndex => AccountSharePeriod) periods;
    }

    struct AccountSharePeriod {
        // The account's BPS share this period
        uint16 bps;
        // Balance sum index where this account share period begins (inclusive)
        uint48 startBalanceSumIndex;
        // Balance sum index where this account share period ends, or MAX_INDEX when active (non-inclusive)
        uint48 endBalanceSumIndex;
        // Block number this checkpoint was initialized
        uint48 initializedAt;
        // Timestamp in seconds at which the account share bps can be decreased or removed by the client
        uint48 removableAt;
        // Tracks the current balance sum position for the last withdrawal per asset
        mapping(address asset => AccountCurrentBalanceSum) currentAssetBalanceSum;
    }

    struct AccountCurrentBalanceSum {
        uint48 currentBalanceSumIndex; // The current asset balance check index for the account
        uint208 previousBalanceSumAtWithdrawal; // The asset balance when it was last withdrawn by the account
    }

    // HELPER CONSTANTS
    uint256 constant public MAX_BPS = BasisPoints.MAX_BPS;
    uint256 constant private MAX_INDEX = type(uint48).max;
    uint256 constant private MAX_BALANCE_SUM_BALANCE = type(uint208).max;

    event AccountShareBpsUpdate(
        address indexed client,
        uint256 indexed balanceShareId,
        address indexed account,
        uint256 newBps,
        uint256 period
    );

    event AccountShareRemovableAtUpdate(
        address indexed client,
        uint256 indexed balanceShareId,
        address indexed account,
        uint256 removableAt,
        uint256 period
    );

    event BalanceShareAssetAllocated(
        address indexed client,
        uint256 indexed balanceShareId,
        address indexed asset,
        uint256 amountAllocated
    );

    error BalanceShareInactive(address client, uint256 balanceShareId);
    error BalanceSumCheckpointIndexOverflow(uint256 maxIndex);
    error InvalidAddress(address account);
    error AccountShareAlreadyExists(address account);
    error AccountShareDoesNotExist(address account);
    error AccountShareNoUpdate(address account);
    error UnauthorizedToEditAccountShares(address client, address msgSender);
    error AccountShareIsCurrentlyLocked(address account, uint256 removableAt);
    error UpdateExceedsMaxTotalBps(uint256 newTotalBps, uint256 maxBps);
    error InvalidMsgValue(uint256 expectedValue, uint256 actualValue);
    error InvalidAssetRemainder(uint256 providedRemainder, uint256 maxRemainder);
    error InvalidAssetAllocation(
        address asset,
        uint256 amountToAllocate,
        uint256 newAssetRemainder,
        uint256 currentAssetRemainder
    );

    /**
     * Sets the provided accounts with the provided BPS values and removable at timestamps for the balance share ID. For
     * each account:
     * - If the account share DOES NOT currently exist for this balance share, this will create a new account share with
     * the provided BPS value and removable at timestamp.
     * - If the account share DOES currently exist for this balance share, this will update the account share with the
     * new BPS value and removable at timestamp.
     * @dev The msg.sender is considered the client. Only each individual client is authorized to make account share
     * updates.
     * @notice If the update decreases the current BPS share or removable at timestamp for the account, then the current
     * block.timestamp must be greater than the account's existing removable at timestamp.
     * @param balanceShareId The uint256 identifier of the client's balance share.
     * @param accounts An array of account addresses to update.
     * @param basisPoints An array of the new basis point share values for each account.
     * @param removableAts An array of the new removable at timestamps, before which the account's BPS cannot be
     * decreased.
     * @return totalBps The new total BPS for the balance share.
     */
    function setAccountShares(
        uint256 balanceShareId,
        address[] memory accounts,
        uint256[] memory basisPoints,
        uint256[] memory removableAts
    ) external returns (uint256 totalBps) {
        if (
            accounts.length != basisPoints.length ||
            accounts.length != removableAts.length
        ) {
            revert IArrayLengthErrors.MismatchingArrayLengths();
        }

        totalBps = _updateAccountShares(msg.sender, balanceShareId, accounts, basisPoints, removableAts);
    }

    /**
     * For the given balance share ID, updates the BPS share for each provided account, or creates a new BPS share for
     * accounts that do not already have an active BPS share (in which case the removable at timestamp will be zero).
     * @param balanceShareId The uint256 identifier of the client's balance share.
     * @param accounts An array of account addresses to update the BPS for.
     * @param basisPoints An array of the new basis point share values for each account.
     * @return totalBps The new total BPS for the balance share.
     */
    function setAccountSharesBps(
        uint256 balanceShareId,
        address[] memory accounts,
        uint256[] memory basisPoints
    ) external returns (uint256 totalBps) {
        if (accounts.length != basisPoints.length) {
            revert IArrayLengthErrors.MismatchingArrayLengths();
        }

        totalBps = _updateAccountShares(msg.sender, balanceShareId, accounts, basisPoints, new uint256[](0));
    }

    /**
     * Updates the removable at timestamps for the provided accounts. Reverts if the account does not have an active
     * BPS share.
     * @param balanceShareId The uint256 identifier of the client's balance share.
     * @param accounts An array of account addresses to update the BPS for.
     * @param removableAts An array of the new removable at timestamps, before which the account's BPS cannot be
     * decreased.
     */
    function setAccountSharesRemovableAts(
        uint256 balanceShareId,
        address[] memory accounts,
        uint256[] memory removableAts
    ) external {
        if (accounts.length != removableAts.length) {
            revert IArrayLengthErrors.MismatchingArrayLengths();
        }

        _updateAccountShares(msg.sender, balanceShareId, accounts, new uint256[](0), removableAts);
    }

    function updateAccountShareAsAccountOwner(
        address client,
        uint256 balanceShareId,
        uint256 newBasisPoints,
        uint256 newRemovableAt
    ) external {
        address[] memory accounts = new address[](1);
        accounts[0] = msg.sender;

        uint256[] memory basisPoints = new uint256[](1);
        basisPoints[0] = newBasisPoints;

        uint256[] memory removableAts = new uint256[](1);
        removableAts[0] = newRemovableAt;

        _updateAccountShares(client, balanceShareId, accounts, basisPoints, removableAts);
    }

    /**
     * @dev Private helper to update account shares by updating or pushing a new AccountSharePeriod.
     * @notice This helper assumes that array length equality checks are performed in the calling function. This
     * function will only check that the accounts array length is not zero.
     *
     * To only update basis points, pass removableAts array length of zero. Vice versa for only updating removableAts.
     */
    function _updateAccountShares(
        address client,
        uint256 balanceShareId,
        address[] memory accounts,
        uint256[] memory basisPoints,
        uint256[] memory removableAts
    ) internal returns (uint256 newTotalBps) {
        if (accounts.length == 0) {
            revert IArrayLengthErrors.MissingArrayItems();
        }

        BalanceShare storage _balanceShare = _getBalanceShare(client, balanceShareId);

        uint256 balanceSumCheckpointIndex = _balanceShare.balanceSumCheckpointIndex;
        uint256 totalBps = _balanceShare.balanceSumCheckpoints[balanceSumCheckpointIndex].totalBps;
        // Increment to a new balance sum checkpoint if we are updating basis points and the current totalBps > 0
        if (basisPoints.length > 0 && totalBps > 0) {
            // Increment checkpoint index in memory and store the update
            unchecked {
                _balanceShare.balanceSumCheckpointIndex = ++balanceSumCheckpointIndex;
            }

            // Don't allow the index to reach MAX_INDEX (end indices are non-inclusive)
            if (balanceSumCheckpointIndex >= MAX_INDEX) {
                revert BalanceSumCheckpointIndexOverflow(MAX_INDEX);
            }
        }

        // Track changes to total BPS
        uint256 increaseTotalBpsBy;
        uint256 decreaseTotalBpsBy;

        // Loop through and update account share periods
        for (uint256 i = 0; i < accounts.length;) {
            // No zero addresses
            if (accounts[i] == address(0)) {
                revert InvalidAddress(accounts[i]);
            }

            AccountShare storage _accountShare = _balanceShare.accounts[accounts[i]];
            AccountSharePeriod storage _accountSharePeriod = _accountShare.periods[_accountShare.periodIndex];

            uint256 currentBps = _accountSharePeriod.bps;
            uint256 currentRemovableAt = _accountSharePeriod.removableAt;

            // No uint16 check on bps because when updating total, it will revert if the total is greater than 10_000
            uint256 newBps = basisPoints.length == 0 ? currentBps : basisPoints[i];
            // Fit removableAt into uint48 (inconsequential if provided value was greater than type(uint48).max)
            uint256 newRemovableAt = Math.min(
                type(uint48).max,
                removableAts.length == 0 ? currentRemovableAt : removableAts[i]
            );

            // Revert if no update
            if (newBps == currentBps && newRemovableAt == currentRemovableAt) {
                revert AccountShareNoUpdate(accounts[i]);
            }

            // If the client is not the msg.sender...
            if (msg.sender != client) {
                // Only update if msg.sender is account owner && they are not increasing BPS or removableAt
                if (
                    msg.sender != accounts[i] ||
                    newBps > currentBps ||
                    newRemovableAt > currentRemovableAt
                ) {
                    revert UnauthorizedToEditAccountShares(client, msg.sender);
                }
            }

            // If decreasing bps or removableAt timestamp, check the account lock
            if (newBps < currentBps || newRemovableAt < currentRemovableAt) {
                // Current timestamp must be greater than the removableAt timestamp (unless msg.sender is owner)
                if (block.timestamp < currentRemovableAt && msg.sender != accounts[i]) {
                    revert AccountShareIsCurrentlyLocked(accounts[i], currentRemovableAt);
                }
            }

            if (newBps != currentBps) {
                // If currentBps is greater than zero, then the account already has an active bps share
                if (currentBps > 0) {
                    // Set end index for current period, then increment period index and update the storage reference
                    _accountSharePeriod.endBalanceSumIndex = uint48(balanceSumCheckpointIndex);
                    _accountSharePeriod = _accountShare.periods[++_accountShare.periodIndex];
                }

                // Track bps changes
                if (newBps > currentBps) {
                    increaseTotalBpsBy += newBps - currentBps;
                } else {
                    decreaseTotalBpsBy += currentBps - newBps;
                }

                // Store new period if the newBps value is greater than zero (otherwise leave uninitialized)
                if (newBps > 0) {
                    _accountSharePeriod.bps = uint16(newBps);
                    _accountSharePeriod.startBalanceSumIndex = uint48(balanceSumCheckpointIndex);
                    _accountSharePeriod.endBalanceSumIndex = uint48(MAX_INDEX);
                    _accountSharePeriod.initializedAt = uint48(block.number);
                    _accountSharePeriod.removableAt = uint48(newRemovableAt);
                }
            } else {
                // No bps change, only updating removableAt
                // Revert if account share does not already exist
                if (currentBps == 0) {
                    revert AccountShareDoesNotExist(accounts[i]);
                }
                _accountSharePeriod.removableAt = uint48(newRemovableAt);
            }

            unchecked { ++i; }
        }

        // Calculate the new total bps, and update in the balance sum checkpoint
        newTotalBps = totalBps + increaseTotalBpsBy - decreaseTotalBpsBy;
        if (newTotalBps > MAX_BPS) {
            revert UpdateExceedsMaxTotalBps(newTotalBps, MAX_BPS);
        }

        _balanceShare.balanceSumCheckpoints[balanceSumCheckpointIndex].totalBps = newTotalBps;
    }

    /**
     * For the provided balance share and asset, returns the amount of the asset to send to this contract for the
     * provided amount that the balance increased by (as a function of the balance share's total BPS).
     * @param client The client account for the balance share.
     * @param balanceShareId The uint256 identifier of the client's balance share.
     * @param asset The ERC20 asset to process the balance share for (address(0) for ETH).
     * @param balanceIncreasedBy The amount that the total balance share increased by.
     * @return amountToAllocate The amount of the asset that should be allocated to the balance share. Mathematically:
     * amountToAllocate = balanceIncreasedBy * totalBps / 10_000
     */
    function getBalanceShareAllocation(
        address client,
        uint256 balanceShareId,
        address asset,
        uint256 balanceIncreasedBy
    ) public view returns (uint256 amountToAllocate) {
        (amountToAllocate,,) = _calculateBalanceShareAllocation(
            _getBalanceShare(client, balanceShareId),
            asset,
            balanceIncreasedBy,
            false
        );
    }

    /**
     * Same as {getBalanceShareAllocation} above, but uses the msg.sender as the "client" parameter.
     */
    function getBalanceShareAllocation(
        uint256 balanceShareId,
        address asset,
        uint256 balanceIncreasedBy
    ) external view override returns (uint256) {
        return getBalanceShareAllocation(msg.sender, balanceShareId, asset, balanceIncreasedBy);
    }

    /**
     * Same as {getBalanceShareAllocation}, but also includes integer remainders from the previous balance allocation.
     * This is useful for calculations with small balance increase amounts relative to the max BPS (10,000). Use this
     * in conjunction with {allocateToBalanceShareWithRemainder} to track the remainders over each allocation.
     * @param client The client account for the balance share.
     * @param balanceShareId The uint256 identifier of the client's balance share.
     * @param asset The ERC20 asset to process the balance share for (address(0) for ETH).
     * @param balanceIncreasedBy The amount that the total balance share increased by.
     * @return amountToAllocate The amount of the asset that should be allocated to the balance share. Mathematically:
     * amountToAllocate = (balanceIncreasedBy + previousAssetRemainder) * totalBps / 10_000
     */
    function getBalanceShareAllocationWithRemainder(
        address client,
        uint256 balanceShareId,
        address asset,
        uint256 balanceIncreasedBy
    ) public view returns (uint256 amountToAllocate) {
        (amountToAllocate,,) = _calculateBalanceShareAllocation(
            _getBalanceShare(client, balanceShareId),
            asset,
            balanceIncreasedBy,
            true
        );
    }

    /**
     * Same as {getBalanceShareAllocationWithRemainder} above, but uses the msg.sender as the "client" parameter.
     */
    function getBalanceShareAllocationWithRemainder(
        uint256 balanceShareId,
        address asset,
        uint256 balanceIncreasedBy
    ) external view override returns (uint256) {
        return getBalanceShareAllocationWithRemainder(msg.sender, balanceShareId, asset, balanceIncreasedBy);
    }

    function _calculateBalanceShareAllocation(
        BalanceShare storage _balanceShare,
        address asset,
        uint256 balanceIncreasedBy,
        bool useRemainder
    ) internal view returns (
        uint256 amountToAllocate,
        uint256 newAssetRemainder,
        BalanceSumCheckpoint storage _currentBalanceSumCheckpoint
    ) {
        _currentBalanceSumCheckpoint = _getCurrentBalanceSumCheckpoint(_balanceShare);

        uint256 totalBps = _currentBalanceSumCheckpoint.totalBps;
        if (totalBps > 0) {
            if (useRemainder) {
                uint256 currentAssetRemainder = _getBalanceSum(_currentBalanceSumCheckpoint, asset).remainder;
                balanceIncreasedBy += currentAssetRemainder;
                newAssetRemainder = balanceIncreasedBy.bpsMulmod(totalBps);
            }

            amountToAllocate = balanceIncreasedBy.bps(totalBps);
        }
    }

    /**
     * Transfers the specified amount to allocate of the given ERC20 asset from the msg.sender to this contract to be
     * split amongst the account shares for this balance share ID.
     * @param client The client account for the balance share.
     * @param balanceShareId The uint256 identifier of the client's balance share.
     * @param asset The ERC20 asset to process the balance share for (address(0) for ETH).
     * @param amountToAllocate The amount of the asset to transfer. This must equal the msg.value for asset address(0),
     * otherwise this contract must be approved to transfer at least this amount for the ERC20 asset.
     */
    function allocateToBalanceShare(
        address client,
        uint256 balanceShareId,
        address asset,
        uint256 amountToAllocate
    ) public payable {
        BalanceShare storage _balanceShare = _getBalanceShare(client, balanceShareId);
        BalanceSumCheckpoint storage _currentBalanceSumCheckpoint = _getCurrentBalanceSumCheckpoint(_balanceShare);

        // Check that the balance share is active
        if (_currentBalanceSumCheckpoint.totalBps == 0) {
            revert BalanceShareInactive(client, balanceShareId);
        }

        // Add the amount to the share (use MAX_BPS for remainder to signal no change)
        _addAssetToBalanceShare(
            _balanceShare,
            _getCurrentBalanceSumCheckpoint(_balanceShare),
            asset,
            amountToAllocate,
            MAX_BPS
        );

        emit BalanceShareAssetAllocated(client, balanceShareId, asset, amountToAllocate);
    }

    /**
     * Same as {allocateToBalanceShare} above, but uses msg.sender as the "client" parameter.
     */
    function allocateToBalanceShare(
        uint256 balanceShareId,
        address asset,
        uint256 amountToAllocate
    ) external payable override {
        allocateToBalanceShare(msg.sender, balanceShareId, asset, amountToAllocate);
    }

    /**
     * Calculates the amount to allocate using the provided amount the balance increased by, adding in the integer
     * remainder from the last balance allocation, and transfers the amount to allocate to this contract. Tracks the
     * resulting remainder for the next function call as well.
     * @notice The msg.sender is used as the client for this function, meaning only the client owner of a balance share
     * can process balance increases with the remainder included. This is to prevent an attack vector where outside
     * parties increment the remainder right up to the threshold.
     * @dev Intended to be used in conjunction with the {getBalanceShareAllocationWithRemainder} function.
     * @param balanceShareId The uint256 identifier of the client's balance share.
     * @param asset The ERC20 asset to process the balance share for (address(0) for ETH).
     * @param balanceIncreasedBy The amount of the asset to transfer. This must equal the msg.value for asset of
     * address(0), otherwise this contract must be approved to transfer at least this amount for the ERC20 asset.
     */
    function allocateToBalanceShareWithRemainder(
        uint256 balanceShareId,
        address asset,
        uint256 balanceIncreasedBy
    ) public payable {
        if (balanceIncreasedBy > 0) {
            BalanceShare storage _balanceShare = _getBalanceShare(msg.sender, balanceShareId);

            // Calculate the amount to allocate and asset remainder internally
            (
                uint256 amountToAllocate,
                uint256 newAssetRemainder,
                BalanceSumCheckpoint storage _currentBalanceSumCheckpoint
            ) = _calculateBalanceShareAllocation(_balanceShare, asset, balanceIncreasedBy, true);

            _addAssetToBalanceShare(
                _balanceShare,
                _currentBalanceSumCheckpoint,
                asset,
                amountToAllocate,
                newAssetRemainder
            );

            emit BalanceShareAssetAllocated(msg.sender, balanceShareId, asset, amountToAllocate);
        }
    }

    /**
     * @dev Helper function that adds the provided asset amount to the balance sum checkpoint. Transfers the
     * amountToAllocate of the ERC20 asset from msg.sender to this contract (or checks that msg.value is equal to the
     * amountToAllocate for an address(0) asset). Also updates the asset remainder unless newAssetRemainder is equal to
     * the MAX_BPS.
     * @notice This function assumes the provided _currentBalanceSumCheckpoint is the CURRENT checkpoint (at the current
     * balanceSumCheckpointIndex).
     */
    function _addAssetToBalanceShare(
        BalanceShare storage _balanceShare,
        BalanceSumCheckpoint storage _currentBalanceSumCheckpoint,
        address asset,
        uint256 amountToAllocate,
        uint256 newAssetRemainder
    ) internal {
        BalanceSumCheckpoint storage _balanceSumCheckpoint = _currentBalanceSumCheckpoint;

        // Transfer the asset to this contract
        if (asset == address(0)) {
            // Validate the msg.value
            if (amountToAllocate != msg.value) {
                revert InvalidMsgValue(amountToAllocate, msg.value);
            }
        } else {
            // No msg.value allowed for ERC20 transfer
            if (msg.value > 0) {
                revert InvalidMsgValue(0, msg.value);
            }
            // Only need to call transfer if the amount is greater than zero
            if (amountToAllocate > 0) {
                SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), amountToAllocate);
            }
        }

        unchecked {
            BalanceSum storage _currentBalanceSum = _getBalanceSum(_balanceSumCheckpoint, asset);

            // TODO: Make the whole while loop in assembly

            // uint256 maxBalanceSum = MAX_BALANCE_SUM_BALANCE;
            // uint256 maxBps = MAX_BPS;
            // /// @solidity memory-safe-assembly
            // assembly {
            //     // Cache current packed BalanceSum slot to memory
            //     let balanceSumPacked := sload(_currentBalanceSum.slot)
            //     // Load current remainder (first 48 bits)
            //     let assetRemainder := and(balanceSumPacked, 0xffffffffffffffff)
            //     // Update to new remainder if the new one is less than MAX_BPS
            //     if lt(newAssetRemainder, maxBps) {
            //         assetRemainder := newAssetRemainder
            //     }
            //     // Load current balance (shift BalanceSum slot right by 48 bits)
            //     let assetBalance := shr(0x30, balanceSumPacked)

            //     for { } true { } {
            //         // Set the balance increase amount in scratch space (do not allow overflow of BalanceSum.balance)
            //         mstore(0, sub(maxBalanceSum, assetBalance))
            //         if lt(amountToAllocate, mload(0)) {
            //             mstore(0, amountToAllocate)
            //         }

            //         // Add to the current balance
            //         assetBalance := add(assetBalance, mload(0))

            //         // Update the slot cache in memory, then store
            //         balanceSumPacked := or(shl(0x30, assetBalance), assetRemainder)
            //         sstore(_currentBalanceSum.slot, balanceSumPacked)

            //         // Finished once the allocation reaches zero
            //         amountToAllocate := sub(amountToAllocate, mload(0))
            //         if eq(amountToAllocate, 0) {
            //             break
            //         }

            //         // If more to allocate, increment the balance sum checkpoint index (copy the totalBps)
            //         let totalBps := sload(_balanceSumCheckpoint.slot)
            //         // Store incremented checkpoint index in scratch space and update in storage
            //         mstore(0, add(sload(_balanceShare.slot), 0x01))
            //         sstore(_balanceShare.slot, mload(0))
            //         // Set the new storage reference for the BalanceSumCheckpoint
            //         // keccak256(_balanceShare.balanceSumCheckpointIndex . _balanceShare.balanceSumCheckpoints.slot))
            //         mstore(0x20, add(_balanceShare.slot, 0x01))
            //         _balanceSumCheckpoint.slot := keccak256(0, 0x40)
            //         // Copy over the totalBps
            //         sstore(_balanceSumCheckpoint.slot, totalBps)

            //         // Reset the current balance to zero in memory, update the BalanceSum reference
            //         // keccak256(address . _balanceSumCheckpoint.balanceSums.slot))
            //         assetBalance := 0
            //         mstore(0, asset)
            //         mstore(0x20, add(_balanceSumCheckpoint.slot, 0x01))
            //         _currentBalanceSum.slot := keccak256(0, 0x40)
            //     }
            // }

            uint256 assetRemainder = _currentBalanceSum.remainder;
            uint256 assetBalance = _currentBalanceSum.balance;
            if (newAssetRemainder < MAX_BPS) {
                assetRemainder = newAssetRemainder;
            }

            while (true) {
                // For each checkpoint, the balance cannot exceed MAX_BALANCE_SUM_BALANCE
                uint256 balanceIncrease = MAX_BALANCE_SUM_BALANCE - assetBalance;
                if (amountToAllocate < balanceIncrease) {
                    balanceIncrease = amountToAllocate;
                }
                assetBalance += balanceIncrease;
                assembly {
                    // Store the packed remainder + balance (shift the assetBalance left by 48 bits)
                    sstore(_currentBalanceSum.slot, or(assetRemainder, shl(0x30, assetBalance)))
                }

                // Finished once the allocation reaches zero
                amountToAllocate -= balanceIncrease;
                if (amountToAllocate == 0) {
                    break;
                }

                // Increment the checkpoint index, update the BalanceSumCheckpoint reference (copy the totalBps)
                uint256 totalBps = _balanceSumCheckpoint.totalBps;
                _balanceSumCheckpoint =
                    _balanceShare.balanceSumCheckpoints[++_balanceShare.balanceSumCheckpointIndex];
                _balanceSumCheckpoint.totalBps = totalBps;
                // Reset currentBalance to zero
                assetBalance = 0;
                // Update the BalanceSum reference
                _currentBalanceSum = _getBalanceSum(_balanceSumCheckpoint, asset);
            }
        }
    }

    // /**
    //  * @dev Processes an account withdrawal, calculating the balance amount that should be paid out to the account. As a
    //  * result of this function, the balance amount to be paid out is marked as withdrawn for this account. The host
    //  * contract is responsible for ensuring this balance is paid out to the account as part of the transaction.
    //  *
    //  * Can only be processed if msg.sender is the account itself, or if msg.sender is approved, or if the account has
    //  * approved anyone (address(0) is approved).
    //  *
    //  * @return balanceToBePaid This is the balance that is marked as paid out for the account. The host contract should
    //  * pay this balance to the account as part of the withdrawal transaction.
    //  */
    // function processAccountWithdrawal(
    //     BalanceShare storage _self,
    //     address account
    // ) internal returns (uint256) {

    //     // Authorize the msg.sender
    //     if (
    //         msg.sender != account &&
    //         !_self._accountWithdrawalApprovals[account][msg.sender] &&
    //         !_self._accountWithdrawalApprovals[account][address(0)]
    //     ) revert Unauthorized();

    //     AccountShare storage accountShare = _self._accounts[account];
    //     (
    //         uint256 balanceToBePaid,
    //         uint256 lastBalanceCheckIndex,
    //         uint256 lastBalancePulled
    //     ) = _calculateAccountBalance(
    //         _self,
    //         accountShare,
    //         true // Revert if the account is already completed their withdrawals, save the gas
    //     );

    //     // Save the account updates to storage
    //     accountShare.lastBalanceCheckIndex = uint40(lastBalanceCheckIndex);
    //     accountShare.lastBalancePulled = lastBalancePulled;
    //     accountShare.lastWithdrawnAt = uint40(block.timestamp);

    //     return balanceToBePaid;
    // }


    // /**
    //  * @dev Approve the provided list of addresses to initiate withdrawal on the account. Approve address(0) to allow
    //  * anyone.
    //  */
    // function approveAddressesForWithdrawal(
    //     BalanceShare storage _self,
    //     address account,
    //     address[] calldata approvedAddresses
    // ) internal {
    //     for (uint256 i = 0; i < approvedAddresses.length;) {
    //         _self._accountWithdrawalApprovals[account][approvedAddresses[i]] = true;
    //         unchecked { ++i; }
    //     }
    // }

    // /**
    //  * @dev Un-approve the provided list of addresses for initiating withdrawals on the account.
    //  */
    // function unapproveAddressesForWithdrawal(
    //     BalanceShare storage _self,
    //     address account,
    //     address[] calldata unapprovedAddresses
    // ) internal {
    //     for (uint256 i = 0; i < unapprovedAddresses.length;) {
    //         _self._accountWithdrawalApprovals[account][unapprovedAddresses[i]] = false;
    //         unchecked { ++i; }
    //     }
    // }

    // /**
    //  * @dev A function for changing the address that an account receives its shares to. This is only callable by the
    //  * account owner. A list of approved addresses for withdrawal can be provided.
    //  *
    //  * Note that by default, if the address(0) was approved (meaning anyone can process a withdrawal to the account),
    //  * then address(0) will be approved for the new account address as well.
    //  *
    //  * @param account The address for the current account share (which must be msg.sender)
    //  * @param newAccount The new address to copy the account share over to.
    //  * @param approvedAddresses A list of addresses to be approved for processing withdrawals to the account receiver.
    //  */
    // function changeAccountAddress(
    //     BalanceShare storage _self,
    //     address account,
    //     address newAccount,
    //     address[] calldata approvedAddresses
    // ) internal {
    //     if (msg.sender != account) revert Unauthorized();
    //     if (newAccount == address(0)) revert InvalidAddress(newAccount);
    //     // Copy it over
    //     _self._accounts[newAccount] = _self._accounts[account];
    //     // Zero out the old account
    //     delete _self._accounts[account];

    //     // Approve addresses
    //     approveAddressesForWithdrawal(_self, newAccount, approvedAddresses);

    //     if (_self._accountWithdrawalApprovals[account][address(0)]) {
    //         _self._accountWithdrawalApprovals[newAccount][address(0)] = true;
    //     }
    // }

    // /**
    //  * @dev The total basis points sum for all currently active account shares.
    //  * @return totalBps An integer representing the total basis points sum. 1 basis point = 0.01%
    //  */
    // function totalBps(
    //     BalanceShare storage _self
    // ) internal view returns (uint256) {
    //     uint256 length = _self._balanceChecks.length;
    //     return length > 0 ?
    //         _self._balanceChecks[length - 1].totalBps :
    //         0;
    // }

    // /**
    //  * @dev Returns the current withdrawable balance for an account share.
    //  * @return balanceAvailable The balance available for withdraw from this account.
    //  */
    // function accountBalance(
    //     BalanceShare storage _self,
    //     address account
    // ) internal view returns (uint256) {
    //     AccountShare storage accountShare = _self._accounts[account];
    //     (uint256 balanceAvailable,,) = _calculateAccountBalance(
    //         _self,
    //         accountShare,
    //         false // Show the zero balance
    //     );
    //     return balanceAvailable;
    // }

    // /**
    //  * @dev A helper function to predict the account balance with an additional "balanceIncreasedBy" parameter (assuming
    //  * the state has not been updated to match yet).
    //  * @return accountBalance Returns the predicted account balance.
    //  */
    // function predictedAccountBalance(
    //     BalanceShare storage _self,
    //     address account,
    //     uint256 balanceIncreasedBy
    // ) internal view returns (uint256) {
    //     AccountShare storage accountShare = _self._accounts[account];
    //     (uint256 balanceAvailable,,) = _calculateAccountBalance(
    //         _self,
    //         accountShare,
    //         false
    //     );
    //     (uint256 addedTotalBalance,) = _calculateBalanceShare(
    //         _self,
    //         balanceIncreasedBy,
    //         accountShare.bps
    //     );
    //     return balanceAvailable + addedTotalBalance.bps(accountShare.bps);
    // }

    // /**
    //  * @dev Returns a bool indicating whether or not the address is approved for withdrawal on the specified account.
    //  */
    // function isAddressApprovedForWithdrawal(
    //     BalanceShare storage _self,
    //     address account,
    //     address address_
    // ) internal view returns (bool) {
    //     return _self._accountWithdrawalApprovals[account][address_];
    // }

    // /**
    //  * @dev Returns the following details (in order) for the specified account:
    //  * - bps
    //  * - createdAt
    //  * - removableAt
    //  * - lastWithdrawnAt
    //  */
    // function accountDetails(
    //     BalanceShare storage _self,
    //     address account
    // ) internal view returns (uint256, uint256, uint256, uint256) {
    //     AccountShare storage accountShare = _self._accounts[account];
    //     return (
    //         accountShare.bps,
    //         accountShare.createdAt,
    //         accountShare.removableAt,
    //         accountShare.lastWithdrawnAt
    //     );
    // }

    // /**
    //  * @dev Private function to calculate the current balance owed to the AccountShare.
    //  * @return accountBalanceOwed The balance owed to the account share.
    //  * @return lastBalanceCheckIndex The resulting lastBalanceCheckIndex for the account.
    //  * @return lastBalancePulled The resulting lastBalancePulled for the account.
    //  */
    // function _calculateAccountBalance(
    //     BalanceShare storage _self,
    //     AccountShare storage accountShare,
    //     bool revertOnWithdrawalsFinished
    // ) private view returns(
    //     uint256 accountBalanceOwed,
    //     uint256,
    //     uint256
    // ) {
    //     (
    //         uint256 bps,
    //         uint256 createdAt,
    //         uint256 endIndex,
    //         uint256 lastBalanceCheckIndex,
    //         uint256 lastBalancePulled
    //     ) = (
    //         accountShare.bps,
    //         accountShare.createdAt,
    //         accountShare.endIndex,
    //         accountShare.lastBalanceCheckIndex,
    //         accountShare.lastBalancePulled
    //     );

    //     // If account is not active or is already finished with withdrawals, return zero
    //     if (_accountHasFinishedWithdrawals(createdAt, lastBalanceCheckIndex, endIndex)) {
    //         if (revertOnWithdrawalsFinished) {
    //             revert AccountWithdrawalsFinished();
    //         }
    //         return (accountBalanceOwed, lastBalanceCheckIndex, lastBalancePulled);
    //     }

    //     uint256 latestBalanceCheckIndex = _self._balanceChecks.length - 1;

    //     // Process each balanceCheck while in range of the endIndex, summing the total balance to be paid
    //     while (lastBalanceCheckIndex <= endIndex) {
    //         BalanceCheck memory balanceCheck = _self._balanceChecks[lastBalanceCheckIndex];
    //         uint256 diff = balanceCheck.balance - lastBalancePulled;
    //         if (diff > 0 && balanceCheck.totalBps > 0) {
    //             // For each check, add (balanceCheck.balance - lastBalancePulled) * (accountBps / balanceCheck.totalBps)
    //             accountBalanceOwed += Math.mulDiv(diff, bps, balanceCheck.totalBps);
    //         }
    //         // Do not increment past the end of the balanceChecks array
    //         if (lastBalanceCheckIndex == latestBalanceCheckIndex) {
    //             // Track this balance to save to the account's storage as the lastPulledBalance
    //             unchecked {
    //                 lastBalancePulled = balanceCheck.balance;
    //             }
    //             break;
    //         }
    //         /**
    //          * @dev Notice that this increments the lastBalanceCheckIndex PAST the endIndex for an account that has had
    //          * their balance share removed at some point.
    //          *
    //          * This is the desired behavior. See the private _accountHasFinishedWithdrawals function. This considers an
    //          * account to be finished with withdrawals once the lastBalanceCheckIndex is greater than the endIndex.
    //          */
    //         unchecked {
    //             lastBalanceCheckIndex += 1;
    //             lastBalancePulled = 0;
    //         }
    //     }

    //     return (accountBalanceOwed, lastBalanceCheckIndex, lastBalancePulled);

    // }

    /// @dev Private helper to retrieve a BalanceShare for the client and balanceShareId (gas optimized)
    function _getBalanceShare(address client, uint256 balanceShareId) private pure returns (BalanceShare storage $) {
        /// @solidity memory-safe-assembly
        assembly {
            /**
             * keccak256(balanceShareId . keccak256(client . _balanceShares.slot))
             */
            mstore(0, client)
            mstore(0x20, _balanceShares.slot)
            mstore(0x20, keccak256(0, 0x40))
            mstore(0, balanceShareId)
            $.slot := keccak256(0, 0x40)
        }
    }

    function _getCurrentBalanceSumCheckpoint(
        BalanceShare storage _balanceShare
    ) private view returns (BalanceSumCheckpoint storage $) {
        /// @solidity memory-safe-assembly
        assembly {
            /**
             * keccak256(_balanceShare.balanceSumCheckpointIndex . _balanceShare.balanceSumCheckpoints.slot))
             */
            mstore(0, sload(_balanceShare.slot))
            mstore(0x20, add(_balanceShare.slot, 0x01))
            $.slot := keccak256(0, 0x40)
        }
    }

    function _getBalanceSum(
        BalanceSumCheckpoint storage _balanceSumCheckpoint,
        address asset
    ) private pure returns (BalanceSum storage $) {
        /// @solidity memory-safe-assembly
        assembly {
            /**
             * keccak256(address . _balanceSumCheckpoint.balanceSums.slot))
             */
            mstore(0, asset)
            mstore(0x20, add(_balanceSumCheckpoint.slot, 0x01))
            $.slot := keccak256(0, 0x40)
        }
    }

}