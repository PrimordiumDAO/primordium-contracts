// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {TreasurerBalanceSharesTest, IERC20} from "./TreasurerBalanceShares.t.sol";

contract TreasurerBalanceSharesERC20Test is TreasurerBalanceSharesTest {
    function setUp() public virtual override {
        ONBOARDER.sharesOnboarderInit.quoteAsset = address(erc20Mock);
        super.setUp();
    }
}