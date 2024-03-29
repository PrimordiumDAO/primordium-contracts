// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {PRBTest} from "@prb/test/PRBTest.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {SnapshotCheckpoints} from "src/libraries/SnapshotCheckpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract SnapshotCheckpointsTest is PRBTest, StdUtils {
    using SnapshotCheckpoints for SnapshotCheckpoints.Trace208;

    // Maximum gap between keys used during the fuzzing tests: the `_prepareKeys` function with make sure that
    // key#n+1 is in the [key#n, key#n + _KEY_MAX_GAP] range.
    uint8 internal constant _KEY_MAX_GAP = 64;

    SnapshotCheckpoints.Trace208 internal _ckpts;

    // helpers
    function _boundUint48(uint48 x, uint48 min, uint48 max) internal pure returns (uint48) {
        return SafeCast.toUint48(_bound(uint256(x), uint256(min), uint256(max)));
    }

    function _prepareKeys(uint48[] memory keys, uint48 maxSpread) internal pure {
        uint48 lastKey = 0;
        for (uint256 i = 0; i < keys.length; ++i) {
            uint48 key = _boundUint48(keys[i], lastKey, lastKey + maxSpread);
            keys[i] = key;
            lastKey = key;
        }
    }

    function _assertLatestCheckpoint(bool exist, uint48 key, uint208 value) internal {
        (bool _exist, uint48 _key, uint208 _value) = _ckpts.latestCheckpoint();
        assertEq(_exist, exist);
        assertEq(_key, key);
        assertEq(_value, value);
    }

    // tests
    function test_Push(uint48[] memory keys, uint208[] memory values, uint48 pastKey) public {
        vm.assume(values.length > 0 && values.length <= keys.length);
        _prepareKeys(keys, _KEY_MAX_GAP);

        // initial state
        assertEq(_ckpts.length(), 0);
        assertEq(_ckpts.latest(), 0);
        _assertLatestCheckpoint(false, 0, 0);

        uint256 duplicates = 0;
        for (uint256 i = 0; i < keys.length; ++i) {
            uint48 key = keys[i];
            uint208 value = values[i % values.length];
            if (i > 0 && key == keys[i - 1]) ++duplicates;

            // push
            _ckpts.push(key, value);

            // check length & latest
            assertEq(_ckpts.length(), i + 1 - duplicates);
            assertEq(_ckpts.latest(), value);
            _assertLatestCheckpoint(true, key, value);
        }

        if (keys.length > 0) {
            uint48 lastKey = keys[keys.length - 1];
            if (lastKey > 0) {
                pastKey = _boundUint48(pastKey, 0, lastKey - 1);

                vm.expectRevert();
                this.push(pastKey, values[keys.length % values.length]);
            }
        }
    }

    function test_PushWithOp(uint48[] memory keys, uint208[] memory values, uint48 pastKey) public {
        vm.assume(values.length > 0 && values.length <= keys.length);
        _prepareKeys(keys, _KEY_MAX_GAP);

        // initial state
        assertEq(_ckpts.length(), 0);
        assertEq(_ckpts.latest(), 0);
        _assertLatestCheckpoint(false, 0, 0);

        uint256 duplicates = 0;
        for (uint256 i = 0; i < keys.length; ++i) {
            uint48 key = keys[i];
            uint208 value = values[i % values.length];
            if (i > 0 && key == keys[i - 1]) ++duplicates;

            // push with op
            uint208 prevValue = _ckpts.latest();
            if (prevValue < value) {
                _ckpts.push(key, _add, value - prevValue);
            } else {
                _ckpts.push(key, _subtract, prevValue - value);
            }

            // check length & latest
            assertEq(_ckpts.length(), i + 1 - duplicates);
            assertEq(_ckpts.latest(), value);
            _assertLatestCheckpoint(true, key, value);
        }

        if (keys.length > 0) {
            uint48 lastKey = keys[keys.length - 1];
            if (lastKey > 0) {
                pastKey = _boundUint48(pastKey, 0, lastKey - 1);

                vm.expectRevert();
                this.push(pastKey, values[keys.length % values.length]);
            }
        }
    }

    function test_PushSnapshot(
        uint48[] memory keys,
        uint208[] memory values,
        uint48[] memory snapshotKeys,
        uint48 pastKey
    )
        public
    {
        // forgefmt: disable-next-item
        vm.assume(
            values.length > 0 &&
            values.length <= keys.length &&
            snapshotKeys.length > 0 &&
            snapshotKeys.length <= keys.length / 4
        );
        _prepareKeys(keys, _KEY_MAX_GAP);
        _prepareKeys(snapshotKeys, _KEY_MAX_GAP);

        // initial state
        assertEq(_ckpts.length(), 0);
        assertEq(_ckpts.latest(), 0);
        _assertLatestCheckpoint(false, 0, 0);

        uint256 duplicates = 0;
        uint256 snapshotSkips = 0;
        uint256 sk = 0; // Current snapshotKey
        for (uint256 i = 0; i < keys.length; ++i) {
            uint48 key = keys[i];
            uint208 value = values[i % values.length];
            uint48 snapshotKey = snapshotKeys[sk];

            if (i > 0) {
                uint48 lastKey = keys[i - 1];
                if (key == lastKey) {
                    ++duplicates;
                } else if (lastKey > snapshotKey) {
                    ++snapshotSkips;
                }
            }

            // push with snapshot check
            _ckpts.push(snapshotKey, key, value);

            // check length & latest
            assertEq(_ckpts.length(), i + 1 - duplicates - snapshotSkips, "Invalid checkpoints length");
            assertEq(_ckpts.latest(), value, "Invalid checkpoints latest value");
            _assertLatestCheckpoint(true, key, value);

            // Update snapshot key every so often
            if (i > Math.mulDiv(keys.length, sk, snapshotKeys.length) && sk < snapshotKeys.length - 1) {
                ++sk;
            }
        }

        if (keys.length > 0) {
            uint48 lastKey = keys[keys.length - 1];
            if (lastKey > 0) {
                pastKey = _boundUint48(pastKey, 0, lastKey - 1);

                vm.expectRevert();
                this.push(pastKey, values[keys.length % values.length]);
            }
        }
    }

    function test_PushSnapshotWithOp(
        uint48[] memory keys,
        uint208[] memory values,
        uint48[] memory snapshotKeys,
        uint48 pastKey
    )
        public
    {
        // forgefmt: disable-next-item
        vm.assume(
            values.length > 0 &&
            values.length <= keys.length &&
            snapshotKeys.length > 0 &&
            snapshotKeys.length <= keys.length / 4
        );
        _prepareKeys(keys, _KEY_MAX_GAP);
        _prepareKeys(snapshotKeys, _KEY_MAX_GAP);

        // initial state
        assertEq(_ckpts.length(), 0);
        assertEq(_ckpts.latest(), 0);
        _assertLatestCheckpoint(false, 0, 0);

        uint256 duplicates = 0;
        uint256 snapshotSkips = 0;
        uint256 sk = 0; // Current snapshotKey
        for (uint256 i = 0; i < keys.length; ++i) {
            uint48 key = keys[i];
            uint208 value = values[i % values.length];
            uint48 snapshotKey = snapshotKeys[sk];

            if (i > 0) {
                uint48 lastKey = keys[i - 1];
                if (key == lastKey) {
                    ++duplicates;
                } else if (lastKey > snapshotKey) {
                    ++snapshotSkips;
                }
            }

            // push op with snapshot check
            uint208 prevValue = _ckpts.latest();
            if (prevValue < value) {
                _ckpts.push(snapshotKey, key, _add, value - prevValue);
            } else {
                _ckpts.push(snapshotKey, key, _subtract, prevValue - value);
            }

            // check length & latest
            assertEq(_ckpts.length(), i + 1 - duplicates - snapshotSkips, "Invalid checkpoints length");
            assertEq(_ckpts.latest(), value, "Invalid checkpoints latest value");
            _assertLatestCheckpoint(true, key, value);

            // Update snapshot key every so often
            if (i > Math.mulDiv(keys.length, sk, snapshotKeys.length) && sk < snapshotKeys.length - 1) {
                ++sk;
            }
        }

        if (keys.length > 0) {
            uint48 lastKey = keys[keys.length - 1];
            if (lastKey > 0) {
                pastKey = _boundUint48(pastKey, 0, lastKey - 1);

                vm.expectRevert();
                this.push(pastKey, values[keys.length % values.length]);
            }
        }
    }

    // used to test reverts
    function push(uint48 key, uint208 value) external {
        _ckpts.push(key, value);
    }

    /// forge-config: default.fuzz.runs = 1048
    /// forge-config: lite.fuzz.runs = 1048
    function test_Lookup(uint48[] memory keys, uint208[] memory values, uint48 lookup) public {
        vm.assume(values.length > 0 && values.length <= keys.length);
        _prepareKeys(keys, _KEY_MAX_GAP);

        uint48 lastKey = keys.length == 0 ? 0 : keys[keys.length - 1];
        lookup = _boundUint48(lookup, 0, lastKey + _KEY_MAX_GAP);

        uint208 upper = 0;
        uint208 lower = 0;
        uint48 lowerKey = type(uint48).max;
        for (uint256 i = 0; i < keys.length; ++i) {
            uint48 key = keys[i];
            uint208 value = values[i % values.length];

            // push
            _ckpts.push(key, value);

            // track expected result of lookups
            if (key <= lookup) {
                upper = value;
            }
            // find the first key that is not smaller than the lookup key
            if (key >= lookup && (i == 0 || keys[i - 1] < lookup)) {
                lowerKey = key;
            }
            if (key == lowerKey) {
                lower = value;
            }
        }

        // check lookup
        assertEq(_ckpts.lowerLookup(lookup), lower, "Lower lookup failed");
        assertEq(_ckpts.upperLookup(lookup), upper, "Upper lookup failed");
        assertEq(_ckpts.upperLookupRecent(lookup), upper, "Upper lookup recent failed");
        assertEq(_ckpts.upperLookupMostRecentSnapshot(lookup), upper, "Upper lookup most recent snapshot failed");
    }

    function _add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    function _subtract(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }
}
