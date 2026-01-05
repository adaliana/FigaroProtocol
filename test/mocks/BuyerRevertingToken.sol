// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestToken} from "./TestToken.sol";

/// @notice Test token that reverts on transferFrom when `from == target`
contract BuyerRevertingToken is TestToken {
    address public target;

    constructor(string memory name_, string memory symbol_, address _target) TestToken(name_, symbol_) {
        target = _target;
    }

    function setTarget(address _t) external {
        target = _t;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (from == target) {
            revert("BuyerRevertingToken: transferFrom reverted for buyer");
        }
        return super.transferFrom(from, to, amount);
    }
}
