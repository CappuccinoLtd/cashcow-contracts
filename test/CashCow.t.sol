// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CashCow} from "../src/CashCow.sol";

contract CashCowTest is Test {
    CashCow public casino;

    function setUp() public {
        casino = new CashCow(address(this));
    }
}
