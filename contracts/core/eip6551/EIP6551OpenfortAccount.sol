// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.19;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC6551Account} from "erc6551/src/interfaces/IERC6551Account.sol";
import {IERC6551Executable} from "erc6551/src/interfaces/IERC6551Executable.sol";
import {ERC6551AccountLib} from "erc6551/src/lib/ERC6551AccountLib.sol";
import {BaseOpenfortAccount, IEntryPoint, SafeCastUpgradeable, ECDSAUpgradeable} from "../BaseOpenfortAccount.sol";
import {TokenCallbackHandler} from "account-abstraction/samples/callback/TokenCallbackHandler.sol";
import "account-abstraction/core/Helpers.sol" as Helpers;

/**
 * @title EIP6551OpenfortAccount (Non-upgradeable)
 * @notice Smart contract wallet with session keys following the ERC-4337 and EIP-6551 standards.
 * It inherits from:
 *  - BaseAccount to comply with ERC-4337
 *  - Initializable because accounts are meant to be created using Factories
 *  - IERC6551Account to have permissions using ERC-721 tokens
 *  - EIP712Upgradeable to use typed structured signatures EIP-712 (supporting ERC-5267 too)
 *  - IERC1271Upgradeable for Signature Validation (ERC-1271)
 *  - TokenCallbackHandler to support ERC-777, ERC-721 and ERC-1155
 */
contract EIP6551OpenfortAccount is BaseOpenfortAccount, IERC6551Account, IERC6551Executable {
    using ECDSAUpgradeable for bytes32;

    address internal entrypointContract;

    // bytes4(keccak256("execute(address,uint256,bytes,uint8)")
    bytes4 internal constant EXECUTE_ERC6551_SELECTOR = 0x51945447;

    uint256 public state;

    event EntryPointUpdated(address oldEntryPoint, address newEntryPoint);

    // solhint-disable-next-line no-empty-blocks
    receive() external payable override(BaseOpenfortAccount, IERC6551Account) {}

    constructor() {
        emit AccountCreated(msg.sender);
        _disableInitializers();
    }

    /*
     * @notice Initialize the smart contract wallet.
     */
    function initialize(address _entrypoint) public initializer {
        if (_entrypoint == address(0)) {
            revert ZeroAddressNotAllowed();
        }
        emit EntryPointUpdated(entrypointContract, _entrypoint);
        entrypointContract = _entrypoint;
        __EIP712_init("Openfort", "0.4");
        state = 1;
    }

    function owner() public view override returns (address) {
        (uint256 chainId, address contractAddress, uint256 tokenId) = token();
        if (chainId != block.chainid) return address(0);
        return IERC721(contractAddress).ownerOf(tokenId);
    }

    /**
     * @dev {See IERC6551Account-token}
     */
    function token() public view virtual override returns (uint256, address, uint256) {
        return ERC6551AccountLib.token();
    }

    function isValidSigner(address signer, bytes calldata) external view override returns (bytes4) {
        if (_isValidSigner(signer)) {
            return IERC6551Account.isValidSigner.selector;
        }

        return bytes4(0);
    }

    function _isValidSigner(address signer) internal view returns (bool) {
        return signer == owner();
    }

    /**
     * @dev {See IERC6551Executable-execute}
     */
    function execute(address _target, uint256 _value, bytes calldata _data, uint8 _operation)
        external
        payable
        override
        returns (bytes memory _result)
    {
        require(_isValidSigner(msg.sender), "Caller is not owner");
        require(_operation == 0, "Only call operations are supported");
        ++state;
        bool success;
        // solhint-disable-next-line avoid-low-level-calls
        (success, _result) = _target.call{value: _value}(_data);
        require(success, string(_result));
        return _result;
    }

    /**
     * Update the EntryPoint address
     */
    function updateEntryPoint(address _newEntrypoint) external {
        if (_newEntrypoint == address(0)) {
            revert ZeroAddressNotAllowed();
        }
        _requireFromOwner();
        ++state;
        emit EntryPointUpdated(entrypointContract, _newEntrypoint);
        entrypointContract = _newEntrypoint;
    }

    /**
     * Return the current EntryPoint
     */
    function entryPoint() public view override returns (IEntryPoint) {
        return IEntryPoint(entrypointContract);
    }
}
