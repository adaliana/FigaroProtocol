// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TestToken} from "./TestToken.sol";
import {Figaro} from "../../src/Figaro.sol";

/// @notice Token that attempts to re-enter Figaro.releaseProcessWithCleanupDeposit
contract ReentrantToken is TestToken {
    Figaro public fig;
    uint256 public targetProcess;
    uint256 public perSrpDeposit;
    address public callerToReenter;

    constructor(string memory name_, string memory symbol_) TestToken(name_, symbol_) {}

    function setReentryTarget(address _fig, uint256 _process, uint256 _perSrpDeposit, address _caller) external {
        fig = Figaro(_fig);
        targetProcess = _process;
        perSrpDeposit = _perSrpDeposit;
        callerToReenter = _caller;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // when buyer's transferFrom is invoked during cleanup deposit collection,
        // attempt to re-enter the Figaro release call
        if (from == callerToReenter && address(fig) != address(0)) {
            // this should revert due to ReentrancyGuard in Figaro
            fig.releaseProcessWithCleanupDeposit(targetProcess, perSrpDeposit);
        }
        return super.transferFrom(from, to, amount);
    }
}
