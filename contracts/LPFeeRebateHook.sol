// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {IAxiomV1Query} from "@axiom-contracts/contracts/interfaces/IAxiomV1Query.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RLPReader} from "@solidity-rlp/contracts/RLPReader.sol";
import {IDynamicFeeManager} from "@uniswap/v4-core/contracts/interfaces/IDynamicFeeManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Fees} from "@uniswap/v4-core/contracts/libraries/Fees.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";

import {BaseHook} from "./BaseHook.sol";

///
///
/// Tiered Fee structure, where Liquidity Providers with more than X liquidity in Pool Y
/// can pay less fee for swapping on Pool Y, well, because they are providing the liquidity to that pool.
///
/// Another possibility is tiered fee structure for cumulated volume traded on Pool Y or all Pools.
///
///
contract BetterFeesForLiquidityProvider is
    BaseHook,
    IDynamicFeeManager,
    Ownable
{
    using Fees for uint24;
    using PoolIdLibrary for IPoolManager.PoolKey;
    using RLPReader for RLPReader.RLPItem;
    using RLPReader for RLPReader.Iterator;
    using RLPReader for bytes;

    error MustUseDynamicFee();

    event AccountAgeVerified(address account, uint32 birthBlock);
    event UpdateAxiomQueryAddress(address newAddress);

    address public axiomQueryAddress;
    address private _currentSwapper;

    mapping(PoolId => mapping(address => uint256)) public liquiditySupplied;

    constructor(
        IPoolManager _poolManager,
        address _axiomQueryAddress
    ) BaseHook(_poolManager) {
        axiomQueryAddress = _axiomQueryAddress;
    }

    ///
    /// ====================
    ///       Uniswap
    /// ====================
    ///

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: true,
                afterInitialize: false,
                beforeModifyPosition: false,
                afterModifyPosition: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false
            });
    }

    ///
    /// @notice Enforce the use of dynamic fee for the pool.
    ///
    function beforeInitialize(
        address,
        IPoolManager.PoolKey calldata key,
        uint160
    ) external pure override returns (bytes4) {
        if (key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    ///
    /// @notice Stores the swapper's address for `getFee` calculation
    /// TODO Use transcient storage for storing swapper address
    ///
    function beforeSwap(
        address sender,
        IPoolManager.PoolKey calldata,
        IPoolManager.SwapParams calldata
    ) external override returns (bytes4) {
        _currentSwapper = sender;
        return BaseHook.beforeSwap.selector;
    }

    ///
    /// @notice Erases the swapper's address for `getFee` calculation
    /// TODO Use transcient storage for storing swapper address
    ///
    function afterSwap(
        address,
        IPoolManager.PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta
    ) external override returns (bytes4) {
        _currentSwapper = address(0);
        return BaseHook.afterSwap.selector;
    }

    ///
    /// IDynamicFeeManager
    ///
    /// TODO Enforce time requirement for liquidity.
    ///       e.g. Liquidity provided must have stayed constant or increased from X in the last Y blocks to
    ///            be counted as X in "liquiditySupplied" for fee change.
    function getFee(
        IPoolManager.PoolKey calldata key
    ) external view returns (uint24 newFee) {
        uint24 startingFee = key.fee;
        // What's a better equation?
        uint24 rebate = uint24(
            _log2(liquiditySupplied[key.toId()][_currentSwapper])
        );

        return rebate + 1 > startingFee ? 1 : startingFee - rebate;
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

    /*  | Name                     | Type                                                                   | Slot | Offset | Bytes | Contract                              |
        |--------------------------|------------------------------------------------------------------------|------|--------|-------|---------------------------------------|
        | controllerGasLimit       | uin256                                                                 | 0    | 0      | 32    | contracts/PoolManager.sol:PoolManager |
        | protocolFeeController    | IProtocolFeeController                                                 | 1    | 0      | 32    | contracts/PoolManager.sol:PoolManager |
        | lockedBy                 | address[]                                                              | 2    | 0      | 32    | contracts/PoolManager.sol:PoolManager |
        | lockStates               | mapping(uint256 index => LockState)                                    | 3    | 0      | 32    | contracts/PoolManager.sol:PoolManager |
        | reservesOf               | mapping(Currency currency => uint256)                                  | 4    | 0      | 32    | contracts/PoolManager.sol:PoolManager |
        | pools                    | mapping(PoolId id => Pool.State) public                                | 5    | 0      | 32    | contracts/PoolManager.sol:PoolManager |
        | protocolFeesAccrued      | mapping(Currency currency => uint256)                                  | 6    | 0      | 32    | contracts/PoolManager.sol:PoolManager |
        | hookFeesAccrued          | mapping(address hookAddress => mapping(Currency currency => uint256))  | 7    | 0      | 32    | contracts/PoolManager.sol:PoolManager |
    */
    /*  | Name                     | Type                                            | Slot | Offset | Bytes | Contract                        |
        |--------------------------|-------------------------------------------------|------|--------|-------|---------------------------------|
        | liquidity                | uint128                                         | 0    | 0      | 32    | libraries/Position.sol:Position |
        | feeGrowthInside0LastX128 | uint256                                         | 1    | 0      | 32    | libraries/Position.sol:Position |
        | feeGrowthInside1LastX128 | uint256                                         | 2    | 0      | 32    | libraries/Position.sol:Position |
    */
    ///
    /// TODO:
    /// 1. Verify storage proof of a Pool's Position (mapping(pools => mapping(position => liquidity_data)))
    /// 2. Check if Position's liquidity data has been used in the last 256 blocks (prevent double-counting)
    /// 3. If (2) is false, then subtract the stale liquidity data of the Position
    /// 4. Then, add the fresh liquidity date of the Position
    ///
    /// NOTE:
    /// - Need to make sure liquidity is not JIT for recording. In other words, check block numbers
    /// - Need to store the block.number for the block in the storage proof, and make records stale as `block.number` progresses.
    ///
    function verifyPositionLiquidity(
        IAxiomV1Query.StorageResponse[] calldata storageProofs,
        IAxiomV1Query.BlockResponse[] calldata blockProofs,
        bytes[1] calldata rlpEncodedHeaders,
        bytes32[3] calldata keccakResponses
    ) external {
        // Only care about `liquidity`
        require(
            storageProofs[0].slot == 5 && storageProofs[2].slot == 5,
            "invalid pools slot"
        );
        require(
            storageProofs[1].slot == 0 && storageProofs[3].slot == 0,
            "invalid liquidity slot"
        );
        require(
            storageProofs[0].blockNumber == storageProofs[1].blockNumber &&
                storageProofs[0].blockNumber == blockProofs[0].blockNumber,
            "inconsistent block number"
        );
        require(
            storageProofs[2].blockNumber == storageProofs[3].blockNumber &&
                storageProofs[2].blockNumber == blockProofs[1].blockNumber,
            "inconsistent block number"
        );
        require(
            blockProofs[1].blockNumber > blockProofs[0].blockNumber,
            "end block must be after start block"
        );

        require(
            IAxiomV1Query(axiomQueryAddress).areResponsesValid(
                keccakResponses[0],
                keccakResponses[1],
                keccakResponses[2],
                blockProofs,
                new IAxiomV1Query.AccountResponse[](0),
                storageProofs
            ),
            "Proof not valid"
        );

        uint256 liquidity0 = uint256(storageProofs[1].value);
        uint256 liquidity1 = uint256(storageProofs[3].value);
        require(liquidity1 >= liquidity0, "only sticky liquidity");

        RLPReader.RLPItem[] memory ls = rlpEncodedHeaders[0]
            .toRlpItem()
            .toList();
        // hmm, is this the correct index
        address owner = ls[0].toAddress();

        // TODO: Get Pool ID
        PoolId poolId = PoolId.wrap(bytes32(0));

        // TODO: Check that the position's liquidity is not double-counted
        liquiditySupplied[poolId][owner] += liquidity1;
    }

    ///
    /// ====================
    ///         Misc.
    /// ====================
    ///

    ///
    /// @notice Copied from https://graphics.stanford.edu/~seander/bithacks.html#IntegerLogDeBruijn.
    ///         Unverified.
    ///
    function _log2(uint x) internal pure returns (uint y) {
        assembly {
            let arg := x
            x := sub(x, 1)
            x := or(x, div(x, 0x02))
            x := or(x, div(x, 0x04))
            x := or(x, div(x, 0x10))
            x := or(x, div(x, 0x100))
            x := or(x, div(x, 0x10000))
            x := or(x, div(x, 0x100000000))
            x := or(x, div(x, 0x10000000000000000))
            x := or(x, div(x, 0x100000000000000000000000000000000))
            x := add(x, 1)
            let m := mload(0x40)
            mstore(
                m,
                0xf8f9cbfae6cc78fbefe7cdc3a1793dfcf4f0e8bbd8cec470b6a28a7a5a3e1efd
            )
            mstore(
                add(m, 0x20),
                0xf5ecf1b3e9debc68e1d9cfabc5997135bfb7a7a3938b7b606b5b4b3f2f1f0ffe
            )
            mstore(
                add(m, 0x40),
                0xf6e4ed9ff2d6b458eadcdf97bd91692de2d4da8fd2d0ac50c6ae9a8272523616
            )
            mstore(
                add(m, 0x60),
                0xc8c0b887b0a8a4489c948c7f847c6125746c645c544c444038302820181008ff
            )
            mstore(
                add(m, 0x80),
                0xf7cae577eec2a03cf3bad76fb589591debb2dd67e0aa9834bea6925f6a4a2e0e
            )
            mstore(
                add(m, 0xa0),
                0xe39ed557db96902cd38ed14fad815115c786af479b7e83247363534337271707
            )
            mstore(
                add(m, 0xc0),
                0xc976c13bb96e881cb166a933a55e490d9d56952b8d4e801485467d2362422606
            )
            mstore(
                add(m, 0xe0),
                0x753a6d1b65325d0c552a4d1345224105391a310b29122104190a110309020100
            )
            mstore(0x40, add(m, 0x100))
            let
                magic
            := 0x818283848586878898a8b8c8d8e8f929395969799a9b9d9e9faaeb6bedeeff
            let
                shift
            := 0x100000000000000000000000000000000000000000000000000000000000000
            let a := div(mul(x, magic), shift)
            y := div(mload(add(m, sub(255, a))), shift)
            y := add(
                y,
                mul(
                    256,
                    gt(
                        arg,
                        0x8000000000000000000000000000000000000000000000000000000000000000
                    )
                )
            )
        }
    }
}
