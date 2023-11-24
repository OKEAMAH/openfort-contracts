// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.19;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title ERC6551OpenfortProxy (Non-upgradeable)
 * @notice Contract to create the ERC6551 proxies
 * It inherits from:
 *  - ERC1967Proxy
 */
contract ERC6551OpenfortProxy is ERC1967Proxy {
    constructor(address _logic, bytes memory _data) ERC1967Proxy(_logic, _data) {}

    function implementation() external view returns (address) {
        return _implementation();
    }
}
