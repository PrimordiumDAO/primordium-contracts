// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../GovernanceSetup.t.sol";

contract TestAccountsSetup is Test, GovernanceSetup {

    address a1 = address(0x01);
    address a2 = address(0x02);
    address a3 = address(0x03);
    address a4 = address(0x04);

    uint256 amnt1 = 1 ether;
    uint256 amnt2 = 2 ether;
    uint256 amnt3 = 3 ether;
    uint256 amntTotal = amnt1 + amnt2 + amnt3;

    constructor() {
        vm.deal(a1, amnt1);
        vm.deal(a2, amnt2);
    }

    function setUp() public virtual {
        // Test various deposit functions
        vm.prank(a1);
        token.deposit{value: amnt1}();
        vm.prank(a2);
        token.depositFor{value: amnt2}(a2);
        token.depositFor{value: amnt3}(a3, amnt3);
        token.depositFor(a4); // Should deposit 0
    }

     function _expectedTokenBalance(uint256 baseAssetAmount) internal view returns(uint256) {
        (uint256 num, uint256 denom) = token.tokenPrice();
        return baseAssetAmount / num * denom;
    }

}