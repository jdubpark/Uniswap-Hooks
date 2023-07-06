// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {IAxiomV1Query} from "@axiom-contracts/contracts/interfaces/IAxiomV1Query.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";

import {BaseHook} from "./BaseHook.sol";

///
///
/// Only old accounts can use the pool.
/// Old is subjective :p It's the hook owner's job to define "old".
///
///
contract OldAccount is BaseHook, Ownable {
    address public axiomQueryAddress;
    uint256 public ageThreshold;

    event UpdateAxiomQueryAddress(address newAddress);
    event UpdateAgeThreshold(uint256 blockNumber);
    event AccountAgeVerified(address account, uint32 birthBlock);

    mapping(address => uint32) public birthBlocks; // Keeps track of first-tx block numbers of each account

    constructor(
        IPoolManager _poolManager,
        address _axiomQueryAddress,
        uint256 _ageThreshold
    ) BaseHook(_poolManager) {
        require(_ageThreshold >= 7200, "cannot be THAT young"); // 7200 slots = 1 day
        axiomQueryAddress = _axiomQueryAddress;
        ageThreshold = _ageThreshold;

        emit UpdateAgeThreshold(ageThreshold);
        emit UpdateAxiomQueryAddress(_axiomQueryAddress);
    }

    modifier onlyPermitOldAccounts(address sender) {
        require(
            uint256(birthBlocks[sender]) != 0,
            "you are not even born, bruh"
        );
        require(
            block.number - uint256(birthBlocks[sender]) >= ageThreshold,
            "you not old enough, yo"
        );
        _;
    }

    function updateAgeThreshold(uint256 _ageThreshold) external onlyOwner {
        require(_ageThreshold >= 7200, "cannot be THAT young"); // 7200 slots = 1 day
        ageThreshold = _ageThreshold;
        emit UpdateAgeThreshold(ageThreshold);
    }

    ///
    /// ====================
    ///       Uniswap
    /// ====================
    ///

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: false,
                afterInitialize: false,
                beforeModifyPosition: false,
                afterModifyPosition: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false
            });
    }

    function beforeModifyPosition(
        address sender,
        IPoolManager.PoolKey calldata,
        IPoolManager.ModifyPositionParams calldata
    )
        external
        view
        override
        poolManagerOnly
        onlyPermitOldAccounts(sender)
        returns (bytes4)
    {
        return BaseHook.beforeModifyPosition.selector;
    }

    function beforeSwap(
        address sender,
        IPoolManager.PoolKey calldata,
        IPoolManager.SwapParams calldata
    )
        external
        view
        override
        poolManagerOnly
        onlyPermitOldAccounts(sender)
        returns (bytes4)
    {
        return BaseHook.beforeSwap.selector;
    }

    ///
    /// ====================
    ///        Axiom
    /// ====================
    ///

    function updateAxiomQueryAddress(
        address _axiomQueryAddress
    ) external onlyOwner {
        axiomQueryAddress = _axiomQueryAddress;
        emit UpdateAxiomQueryAddress(_axiomQueryAddress);
    }

    ///
    /// @notice Verifies age of an account using a ZK proof, where age is the block number of the
    ///         first transaction of the account.
    ///
    function verifyAge(
        IAxiomV1Query.AccountResponse[] calldata accountProofs,
        bytes32[3] calldata keccakResponses
    ) external {
        require(accountProofs.length == 2, "Too many account proofs");
        address account = accountProofs[0].addr;
        require(account == accountProofs[1].addr, "Accounts are not the same");
        require(
            accountProofs[0].blockNumber + 1 == accountProofs[1].blockNumber,
            "Block numbers are not consecutive"
        );
        require(accountProofs[0].nonce == 0, "Prev block nonce is not 0");
        require(
            accountProofs[1].nonce > 0,
            "No account transactions in curr block"
        );
        uint256 addrSize;
        assembly {
            addrSize := extcodesize(account)
        }
        require(addrSize == 0, "Account is a contract");

        require(
            IAxiomV1Query(axiomQueryAddress).areResponsesValid(
                keccakResponses[0],
                keccakResponses[1],
                keccakResponses[2],
                new IAxiomV1Query.BlockResponse[](0),
                accountProofs,
                new IAxiomV1Query.StorageResponse[](0)
            ),
            "Proof not valid"
        );

        birthBlocks[account] = accountProofs[0].blockNumber;
        emit AccountAgeVerified(account, accountProofs[0].blockNumber);
    }
}
