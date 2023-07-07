// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";

import {BaseHook} from "./BaseHook.sol";

/**
 * @title An interface for checking whether an address has a valid kycNFT token
 */
interface IKycValidity {
    /// @dev Check whether a given address has a valid kycNFT token
    /// @param _addr Address to check for tokens
    /// @return valid Whether the address has a valid token
    function hasValidToken(address _addr) external view returns (bool valid);
}

/**
 * Only KYC'ed people can trade on the V4 hook'ed pool.
 * Caveat: Relies on external oracle for info on an address's KYC status.
 */
contract KYCSwaps is BaseHook, Ownable {
    IKycValidity public kycValidity;
    address private _preKycValidity;
    uint256 private _setKycValidityReqTimestamp;

    constructor(
        IPoolManager _poolManager,
        address _kycValidity
    ) BaseHook(_poolManager) {
        kycValidity = IKycValidity(_kycValidity);
    }

    modifier onlyPermitKYC() {
        require(
            kycValidity.hasValidToken(tx.origin),
            "Swaps available for valid KYC token holders"
        );
        _;
    }

    /// Sorta timelock
    function setKycValidity(address _kycValidity) external onlyOwner {
        if (
            block.timestamp - _setKycValidityReqTimestamp >= 7 days &&
            _kycValidity == _preKycValidity
        ) {
            kycValidity = IKycValidity(_kycValidity);
        } else {
            _preKycValidity = _kycValidity;
            _setKycValidityReqTimestamp = block.timestamp;
        }
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: false,
                afterInitialize: false,
                beforeModifyPosition: true,
                afterModifyPosition: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false
            });
    }

    function beforeModifyPosition(
        address,
        IPoolManager.PoolKey calldata,
        IPoolManager.ModifyPositionParams calldata
    ) external view override poolManagerOnly onlyPermitKYC returns (bytes4) {
        return BaseHook.beforeModifyPosition.selector;
    }

    function beforeSwap(
        address,
        IPoolManager.PoolKey calldata,
        IPoolManager.SwapParams calldata
    ) external view override poolManagerOnly onlyPermitKYC returns (bytes4) {
        return BaseHook.beforeSwap.selector;
    }
}
