// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title NonOwnableMintableERC20
/// @notice Minimal ERC20 used in tests where the token does not expose `owner()`.
contract NonOwnableMintableERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
