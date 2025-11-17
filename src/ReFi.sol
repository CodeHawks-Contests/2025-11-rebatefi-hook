// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;


import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";


contract ReFi is ERC20, Ownable {
    constructor() ERC20("RebateFi", "ReFi") Ownable(msg.sender) {
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}