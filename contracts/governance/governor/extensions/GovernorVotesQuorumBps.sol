// SPDX-License-Identifier: MIT
// Primordium Contracts
// Based on OpenZeppelin Contracts (last updated v4.8.0) (governance/extensions/GovernorVotesQuorumBps.sol)

pragma solidity ^0.8.0;

import "./GovernorVotes.sol";
import "@openzeppelin/contracts/utils/Checkpoints.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @dev Extension of {Governor} for voting weight extraction from an {ERC20Votes} token and a quorum expressed as a
 * fraction of the total supply, in basis points.
 *
 * The DAO can set the {quorumBps} to zero to allow any vote to pass without a quorum.
 *
 * _Available since v4.3._
 */
abstract contract GovernorVotesQuorumBps is GovernorVotes {

    uint256 constant MAX_BPS = 10_000;

    using SafeCast for *;
    using Checkpoints for Checkpoints.Trace224;

    Checkpoints.Trace224 private _quorumBpsCheckpoints;

    event QuorumBpsUpdated(uint256 oldQuorumBps, uint256 newQuorumBps);

    /**
     * @dev Initialize quorum as a fraction of the token's total supply.
     *
     * The fraction is specified as `bps / denominator`. By default the denominator is 10_000, so quorum is
     * specified as a percent: a bps of 1_000 corresponds to quorum being 10% of total supply. The denominator can
     * be customized by overriding {quorumDenominator}.
     */
    constructor(uint256 quorumBps_) {
        _updateQuorumBps(quorumBps_);
    }

    /**
     * @dev Returns the current quorum bps. See {quorumDenominator}.
     */
    function quorumBps() public view virtual returns (uint256) {
        return _quorumBpsCheckpoints.latest();
    }

    /**
     * @dev Returns the quorum bps at a specific timepoint. See {quorumDenominator}.
     */
    function quorumBps(uint256 timepoint) public view virtual returns (uint256) {
        // Optimistic search, check the latest checkpoint
        (bool exists, uint256 _key, uint256 _value) = _quorumBpsCheckpoints.latestCheckpoint();
        if (exists && _key <= timepoint) {
            return _value;
        }

        // Otherwise, do the binary search
        return _quorumBpsCheckpoints.upperLookupRecent(timepoint.toUint32());
    }

    /**
     * @dev Returns the quorum for a timepoint, in terms of number of votes: `supply * bps / denominator`.
     */
    function quorum(uint256 timepoint) public view virtual override returns (uint256) {
        // Check for zero bps to save gas
        uint256 bps = quorumBps(timepoint);
        if (bps == 0) return 0;
        // NOTE: We don't need Math.mulDiv for overflow AS LONG AS the max supply of the token is <= type(uint224).max
        return (_token.getPastTotalSupply(timepoint) * quorumBps(timepoint)) / MAX_BPS;
    }

    /**
     * @dev Changes the quorum bps.
     *
     * Emits a {QuorumBpsUpdated} event.
     *
     * Requirements:
     *
     * - Must be called through a governance proposal.
     * - New bps must be smaller or equal to the denominator.
     */
    function updateQuorumBps(uint256 newQuorumBps) external virtual onlyGovernance {
        _updateQuorumBps(newQuorumBps);
    }

    /**
     * @dev Changes the quorum bps.
     *
     * Emits a {QuorumBpsUpdated} event.
     *
     * Requirements:
     *
     * - New bps must be smaller or equal to the denominator.
     */
    function _updateQuorumBps(uint256 newQuorumBps) internal virtual {
        require(
            newQuorumBps <= MAX_BPS,
            "GovernorVotesQuorumBps: quorumBps over 10_000"
        );

        uint256 oldQuorumBps = quorumBps();

        // Make sure we keep track of the original bps in contracts upgraded from a version without checkpoints.
        if (oldQuorumBps != 0 && _quorumBpsCheckpoints.length() == 0) {
            _quorumBpsCheckpoints._checkpoints.push(
                Checkpoints.Checkpoint224({_key: 0, _value: oldQuorumBps.toUint224()})
            );
        }

        // Set new quorum for future proposals
        _quorumBpsCheckpoints.push(clock().toUint32(), newQuorumBps.toUint224());

        emit QuorumBpsUpdated(oldQuorumBps, newQuorumBps);
    }
}