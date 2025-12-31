// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title OwnableMintableERC20
/// @notice Minimal ERC20 used in tests where the token must expose `owner()` for `onlyTokenOwner` checks.
/// @dev Not intended for production use.
contract OwnableMintableERC20 is ERC20, Ownable {
    /// @param name_ ERC20 name.
    /// @param symbol_ ERC20 symbol.
    /// @param initialOwner Address that can mint.
    constructor(
        string memory name_,
        string memory symbol_,
        address initialOwner
    )
        ERC20(name_, symbol_)
        Ownable(initialOwner)
    { }

    /// @notice Mints `amount` tokens to `to`.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
