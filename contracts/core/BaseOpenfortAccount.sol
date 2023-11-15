// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.19;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ECDSAUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IERC1271Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC1271Upgradeable.sol";
import {SafeCastUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {BaseAccount, UserOperation, IEntryPoint, UserOperationLib} from "account-abstraction/core/BaseAccount.sol";
import {TokenCallbackHandler} from "account-abstraction/samples/callback/TokenCallbackHandler.sol";
import {_packValidationData} from "account-abstraction/core/Helpers.sol";

/**
 * @title BaseOpenfortAccount (Non upgradeable by default)
 * @notice Minimal smart contract wallet with session keys following the ERC-4337 standard.
 * It inherits from:
 *  - BaseAccount to comply with ERC-4337
 *  - Initializable because accounts are meant to be created using Factories
 *  - EIP712Upgradeable to use typed structured signatures EIP-712 (supporting ERC-5267 too)
 *  - IERC1271Upgradeable for Signature Validation (ERC-1271)
 *  - TokenCallbackHandler to support ERC-777, ERC-721 and ERC-1155
 */
abstract contract BaseOpenfortAccount is
    BaseAccount,
    Initializable,
    EIP712Upgradeable,
    IERC1271Upgradeable,
    TokenCallbackHandler
{
    using ECDSAUpgradeable for bytes32;

    // bytes4(keccak256("isValidSignature(bytes32,bytes)")
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;
    // bytes4(keccak256("execute(address,uint256,bytes)")
    bytes4 internal constant EXECUTE_SELECTOR = 0xb61d27f6;
    // bytes4(keccak256("executeBatch(address[],uint256[],bytes[])")
    bytes4 internal constant EXECUTEBATCH_SELECTOR = 0x47e1da2a;
    // keccak256("OpenfortMessage(bytes32 hashedMessage)");
    bytes32 private constant OF_MSG_TYPEHASH = 0x57159f03b9efda178eab2037b2ec0b51ce11be0051b8a2a9992c29dc260e4a30;

    /**
     * Struct like ValidationData (from the EIP-4337) - alpha solution - to keep track of session keys' data
     * @param validAfter this sessionKey is valid only after this timestamp.
     * @param validUntil this sessionKey is valid only until this timestamp.
     * @param limit limit of uses remaining
     * @param masterSessionKey if set to true, the session key does not have any limitation other than the validity time
     * @param whitelising if set to true, the session key has to follow whitelisting rules
     * @param whitelist - this session key can only interact with the addresses in the whitelist.
     */
    struct SessionKeyStruct {
        uint48 validAfter;
        uint48 validUntil;
        uint48 limit;
        bool masterSessionKey;
        bool whitelising;
        mapping(address => bool) whitelist;
        address registrarAddress;
    }

    mapping(address => SessionKeyStruct) public sessionKeys;

    event AccountCreated(address indexed creator);
    event SessionKeyRegistered(address indexed key);
    event SessionKeyRevoked(address indexed key);

    error ZeroAddressNotAllowed();
    error NotOwnerOrEntrypoint();
    error NotOwner();
    error InvalidParameterLength();

    receive() external payable virtual {}

    constructor() {
        emit AccountCreated(msg.sender);
        _disableInitializers();
    }

    /**
     * Require the function call went through EntryPoint or owner
     */
    function _requireFromEntryPointOrOwner() internal view {
        if (msg.sender != address(entryPoint()) && msg.sender != owner()) {
            revert NotOwnerOrEntrypoint();
        }
    }

    /**
     * Require the function call went through owner
     */
    function _requireFromOwner() internal view {
        if (msg.sender != owner()) {
            revert NotOwner();
        }
    }

    function owner() public view virtual returns (address);

    /**
     * Check current account deposit in the entryPoint
     */
    function getDeposit() public view returns (uint256) {
        return entryPoint().balanceOf(address(this));
    }

    /*
     * @notice Return whether a sessionKey is valid.
     */
    function isValidSessionKey(address _sessionKey, bytes calldata callData) public returns (bool) {
        SessionKeyStruct storage sessionKey = sessionKeys[_sessionKey];
        // If not owner and the session key is revoked, return false
        if (sessionKey.validUntil == 0) return false;

        // If the sessionKey was not registered by the owner, return false
        if (sessionKey.registrarAddress != owner()) return false;

        // If the signer is a session key that is still valid
        // Let's first get the selector of the function that the caller is using
        bytes4 funcSelector =
            callData[0] | (bytes4(callData[1]) >> 8) | (bytes4(callData[2]) >> 16) | (bytes4(callData[3]) >> 24);

        if (funcSelector == EXECUTE_SELECTOR) {
            // Limit of transactions per sessionKey reached
            if (sessionKey.limit == 0) return false;
            // Deduct one use of the limit for the given session key
            unchecked {
                sessionKey.limit = sessionKey.limit - 1;
            }

            // Check if it is a masterSessionKey
            if (sessionKey.masterSessionKey) {
                return true;
            }

            // If it is not a masterSessionKey, let's check for whitelisting and reentrancy
            address toContract;
            (toContract,,) = abi.decode(callData[4:], (address, uint256, bytes));
            if (toContract == address(this)) {
                return false;
            } // Only masterSessionKey can reenter

            // If there is no whitelist or there is, but the target is whitelisted, return true
            if (!sessionKey.whitelising || sessionKey.whitelist[toContract]) {
                return true;
            }

            return false; // All other cases, deny
        } else if (funcSelector == EXECUTEBATCH_SELECTOR) {
            (address[] memory toContracts,,) = abi.decode(callData[4:], (address[], uint256[], bytes[]));
            // Check if limit of transactions per sessionKey reached
            if (sessionKey.limit < toContracts.length || toContracts.length > 9) return false;
            unchecked {
                sessionKey.limit = sessionKey.limit - SafeCastUpgradeable.toUint48(toContracts.length);
            }

            // Check if it is a masterSessionKey (no whitelist applies)
            if (sessionKey.masterSessionKey) return true;

            for (uint256 i = 0; i < toContracts.length;) {
                if (toContracts[i] == address(this)) {
                    return false;
                } // Only masterSessionKey can reenter
                if (sessionKey.whitelising && !sessionKey.whitelist[toContracts[i]]) {
                    return false;
                } // One contract's not in the sessionKey's whitelist (if any)
                unchecked {
                    ++i; // gas optimization
                }
            }
            return true;
        }

        // If a session key is used for other functions other than execute() or executeBatch(), deny
        return false;
    }

    /*
     * @notice See EIP-1271
     * Owner and session keys need to sign using EIP712.
     */
    function isValidSignature(bytes32 _hash, bytes memory _signature) public view override returns (bytes4) {
        bytes32 structHash = keccak256(abi.encode(OF_MSG_TYPEHASH, _hash));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = digest.recover(_signature);
        if (owner() == signer) return MAGICVALUE;

        SessionKeyStruct storage sessionKey = sessionKeys[signer];
        // If the signer is a session key that is still valid
        if (
            sessionKey.validUntil == 0 || sessionKey.validAfter > block.timestamp
                || sessionKey.validUntil < block.timestamp || sessionKey.limit < 1
        ) {
            return 0xffffffff;
        } // Not owner or session key revoked
        else if (sessionKey.registrarAddress != owner()) {
            return 0xffffffff;
        } else {
            return MAGICVALUE;
        }
    }

    /**
     * Execute a transaction (called directly from owner, or by entryPoint)
     */
    function execute(address dest, uint256 value, bytes calldata func) public virtual {
        _requireFromEntryPointOrOwner();
        _call(dest, value, func);
    }

    /**
     * Execute a sequence of transactions. Maximum 9.
     */
    function executeBatch(address[] calldata _target, uint256[] calldata _value, bytes[] calldata _calldata)
        public
        virtual
    {
        _requireFromEntryPointOrOwner();
        if (_target.length > 9 || _target.length != _calldata.length || _target.length != _value.length) {
            revert InvalidParameterLength();
        }
        for (uint256 i = 0; i < _target.length;) {
            _call(_target[i], _value[i], _calldata[i]);
            unchecked {
                ++i; // gas optimization
            }
        }
    }

    /**
     * Deposit funds for this account in the EntryPoint
     */
    function addDeposit() public payable {
        entryPoint().depositTo{value: msg.value}(address(this));
    }

    /**
     * Withdraw value from the account's deposit
     * @param _withdrawAddress target to send to
     * @param _amount to withdraw
     * @notice ONLY the owner can call this function (it's not using _requireFromEntryPointOrOwner())
     */
    function withdrawDepositTo(address payable _withdrawAddress, uint256 _amount) external {
        _requireFromOwner();
        entryPoint().withdrawTo(_withdrawAddress, _amount);
    }

    /**
     * @dev Call a target contract and reverts if it fails.
     */
    function _call(address _target, uint256 _value, bytes calldata _calldata) internal {
        (bool success, bytes memory result) = _target.call{value: _value}(_calldata);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /**
     * @inheritdoc BaseAccount
     */
    function _validateSignature(UserOperation calldata userOp, bytes32 userOpHash)
        internal
        override
        returns (uint256 validationData)
    {
        // require(entryPoint().getUserOpHash(userOp) == userOpHash, "MEEECK!");
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        address signer = hash.recover(userOp.signature);

        // If the userOp was signed by the owner, allow straightaway
        if (owner() == signer) return 0;

        // Check if the session key is valid according to the data in the userOp
        if (isValidSessionKey(signer, userOp.callData)) {
            return _packValidationData(false, sessionKeys[signer].validUntil, sessionKeys[signer].validAfter);
        }

        return SIG_VALIDATION_FAILED;
    }

    /**
     * Register a session key to the account
     * @param _key session key to register
     * @param _validAfter - this session key is valid only after this timestamp.
     * @param _validUntil - this session key is valid only up to this timestamp.
     * @param _limit - limit of uses remaining.
     * @param _whitelist - this session key can only interact with the addresses in the _whitelist.
     */
    function registerSessionKey(
        address _key,
        uint48 _validAfter,
        uint48 _validUntil,
        uint48 _limit,
        address[] calldata _whitelist
    ) public {
        _requireFromEntryPointOrOwner();

        require(_whitelist.length < 11, "Whitelist too big");
        uint256 i = 0;
        for (i; i < _whitelist.length;) {
            sessionKeys[_key].whitelist[_whitelist[i]] = true;
            unchecked {
                ++i; // gas optimization
            }
        }
        if (i > 0) {
            // If there was some whitelisting, it is not a masterSessionKey
            sessionKeys[_key].whitelising = true;
            sessionKeys[_key].masterSessionKey = false;
        } else {
            if (_limit == ((2 ** 48) - 1)) sessionKeys[_key].masterSessionKey = true;
            else sessionKeys[_key].masterSessionKey = false;
        }

        sessionKeys[_key].validAfter = _validAfter;
        sessionKeys[_key].validUntil = _validUntil;
        sessionKeys[_key].limit = _limit;
        sessionKeys[_key].registrarAddress = owner();

        emit SessionKeyRegistered(_key);
    }

    /**
     * Revoke a session key from the account
     * @param _key session key to revoke
     */
    function revokeSessionKey(address _key) external {
        _requireFromEntryPointOrOwner();
        if (sessionKeys[_key].validUntil != 0) {
            sessionKeys[_key].validUntil = 0;
            sessionKeys[_key].masterSessionKey = false;
            sessionKeys[_key].registrarAddress = address(0);
            emit SessionKeyRevoked(_key);
        }
    }

    function version() external pure virtual returns (uint256) {
        return 1;
    }
}
