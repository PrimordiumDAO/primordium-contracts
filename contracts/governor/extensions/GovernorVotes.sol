// SPDX-License-Identifier: MIT
// Primordium Contracts
// Based on OpenZeppelin Contracts (last updated v4.6.0) (extensions/GovernorVotes.sol)

pragma solidity ^0.8.4;

import "../Governor.sol";
import "../../token/Votes.sol";

/**
 * @dev Extension of {Governor} for voting weight extraction from an {ERC20Votes} token, or since v4.5 an {ERC721Votes}
 * token.
 *
 * _Available since v4.3._
 */
abstract contract GovernorVotes is Governor {

    /**
     * Read the voting weight from the token's built in snapshot mechanism (see {Governor-_getVotes}).
     */
    function _getVotes(
        address account,
        uint256 timepoint,
        bytes memory /*params*/
    ) internal view virtual override returns (uint256) {
        return _token.getPastVotes(account, timepoint);
    }

}