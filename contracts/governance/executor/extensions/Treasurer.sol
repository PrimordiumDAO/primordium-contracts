// SPDX-License-Identifier: MIT
// Primordium Contracts

pragma solidity ^0.8.0;

import "../../token/extensions/VotesProvisioner.sol";
import "../Executor.sol";
import "../../utils/BalanceShares.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract Treasurer is Executor {

    using BalanceShares for BalanceShares.BalanceShare;

    BalanceShares.BalanceShare private _revenueShares;

    VotesProvisioner internal immutable _votes;

    IERC20 internal immutable _baseAsset;

    constructor(
        VotesProvisioner votes_
    ) {
        _votes = votes_;
        _baseAsset = IERC20(votes_.baseAsset());
    }

    function votes() public view returns(address) {
        return address(_votes);
    }

    modifier onlyVotes() {
        require(_msgSender() == address(_votes), "Treasurer: call must come from the _votes contract.");
        _;
    }

    function baseAsset() public view returns (address) {
        return address(_baseAsset);
    }

    function registerDepositERC20(uint256 depositAmount) public virtual onlyVotes {
        _registerDeposit(depositAmount);
    }

    function registerDepositETH(uint256 depositAmount) public payable virtual onlyVotes {
        require(msg.value == depositAmount, "Treasurer: depositEth mismatching depositAmount and msg.value");
        _registerDeposit(depositAmount);
    }

    function _registerDeposit(uint256 depositAmount) private {
        // NEED TO IMPLEMENT BALANCE CHECKS
    }

    function processWithdrawalERC20(address receiver, uint256 withdrawAmount) public virtual onlyVotes {
        _processWithdrawal(withdrawAmount);
        SafeERC20.safeTransfer(_baseAsset, receiver, withdrawAmount);
    }

    function processWithdrawalETH(address receiver, uint256 withdrawAmount) public virtual onlyVotes {
        _processWithdrawal(withdrawAmount);
        (bool success,) = receiver.call{value: withdrawAmount}("");
        if (!success) revert("Treasurer: Failed to process ETH withdrawal.");
    }

    function _processWithdrawal(uint256 withdrawAmount) private {
        // NEED TO IMPLEMENT BALANCE CHECKS
    }


    function addRevenueShare(
        BalanceShares.NewAccountShare memory newAccountShare
    ) public onlyTimelock {
        // RUN BALANCES UPDATE
        // THEN ADD REVENUE SHARE USING LIBRARY
    }

}