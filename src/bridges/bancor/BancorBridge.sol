// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec
pragma solidity >=0.8.4;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AztecTypes} from "rollup-encoder/libraries/AztecTypes.sol";
import {IRollupProcessor} from "rollup-encoder/interfaces/IRollupProcessor.sol";
import {ErrorLib} from "../base/ErrorLib.sol";
import {IWETH} from "../../interfaces/IWETH.sol";
import {BridgeBase} from "../base/BridgeBase.sol";
import {IBancorNetwork} from "../../interfaces/bancor/IBancorNetwork.sol";
import {Token} from "../../interfaces/bancor/support/Token.sol";


/**
 * @title Aztec Connect Bridge for swapping on Bancor
 * @notice You can use this contract to swap tokens on Bancor v3 VIA the Bancor Omnipool.
 */
contract BancorBridge is BridgeBase {
    using SafeERC20 for IERC20;

    struct TradeData {
      uint256 minReturnAmount;
      uint256 deadline;
    }

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // @dev Event which is emitted when the output token doesn't implement decimals().

    IBancorNetwork public constant BANCOR = IBancorNetwork(0xeEF417e1D5CC832e619ae18D2F140De2999dD4fB);


    /**
     * @notice Set the address of rollup processor.
     * @param _rollupProcessor Address of rollup processor
     */
    constructor(address _rollupProcessor) BridgeBase(_rollupProcessor) {}

    // @dev Empty method which is present here in order to be able to receive ETH when unwrapping WETH.
    receive() external payable {}

    /**
     * @notice Sets all the important approvals.
     * @param _tokensIn - An array of address of input tokens (tokens to later swap in the convert(...) function)
     * @param _tokensOut - An array of address of output tokens (tokens to later return to rollup processor)
     * @dev SwapBridge never holds any ERC20 tokens after or before an invocation of any of its functions. For this
     * reason the following is not a security risk and makes convert(...) function more gas efficient.
     */
    function preApproveTokens(address[] calldata _tokensIn, address[] calldata _tokensOut) external {
        uint256 tokensLength = _tokensIn.length;
        for (uint256 i; i < tokensLength;) {
            address tokenIn = _tokensIn[i];
            // Using safeApprove(...) instead of approve(...) and first setting the allowance to 0 because underlying
            // can be Tether
            IERC20(tokenIn).safeApprove(address(BANCOR), 0);
            IERC20(tokenIn).safeApprove(address(BANCOR), type(uint256).max);
            unchecked {
                ++i;
            }
        }
        tokensLength = _tokensOut.length;
        for (uint256 i; i < tokensLength;) {
            address tokenOut = _tokensOut[i];
            // Using safeApprove(...) instead of approve(...) and first setting the allowance to 0 because underlying
            // can be Tether
            IERC20(tokenOut).safeApprove(address(ROLLUP_PROCESSOR), 0);
            IERC20(tokenOut).safeApprove(address(ROLLUP_PROCESSOR), type(uint256).max);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice A function which swaps input token for output token along the path encoded in _auxData.
     * @param _inputAssetA - Input ERC20 token
     * @param _outputAssetA - Output ERC20 token
     * @param _totalInputValue - Amount of input token to swap
     * @param _interactionNonce - Interaction nonce
     * @param _auxData - Encodeds minimum return amount and deadline information
     * @param _rollupBeneficiary - Address which receives subsidy if the call is eligible for it
     * @return outputValueA - The amount of output token received
     */
    function convert(
        AztecTypes.AztecAsset calldata _inputAssetA,
        AztecTypes.AztecAsset calldata _inputAssetB,
        AztecTypes.AztecAsset calldata _outputAssetA,
        AztecTypes.AztecAsset calldata _outputAssetB,
        uint256 _totalInputValue,
        uint256 _interactionNonce,
        uint64 _auxData,
        address _rollupBeneficiary
    ) external payable override (BridgeBase) onlyRollup returns (uint256 outputValueA, uint256, bool) {
        // Accumulate subsidy to _rollupBeneficiary
        SUBSIDY.claimSubsidy(
          computeCriteria(_inputAssetA, _inputAssetB, _outputAssetA, _outputAssetB, _auxData), _rollupBeneficiary
        );

        bool inputIsEth = _inputAssetA.assetType == AztecTypes.AztecAssetType.ETH;
        bool outputIsEth = _outputAssetA.assetType == AztecTypes.AztecAssetType.ETH;

        if (_inputAssetA.assetType != AztecTypes.AztecAssetType.ERC20 && !inputIsEth) {
            revert ErrorLib.InvalidInputA();
        }
        if (_outputAssetA.assetType != AztecTypes.AztecAssetType.ERC20 && !outputIsEth) {
            revert ErrorLib.InvalidOutputA();
        }

        Token iT = Token(_inputAssetA.erc20Address);

        Token oT = Token(_outputAssetA.erc20Address);


        TradeData memory td = _decodeTradeData(_auxData);

            // Swap using the first swap path
            outputValueA = BANCOR.tradeBySourceAmount(
              iT,
              oT,
              _totalInputValue,
              td.minReturnAmount,
              td.deadline,
              _rollupBeneficiary
            );

            if (outputIsEth) {
                IWETH(WETH).withdraw(outputValueA);
                IRollupProcessor(ROLLUP_PROCESSOR).receiveEthFromBridge{value: outputValueA}(_interactionNonce);
            }
    }


    /**
     * @notice encodes a uint256 token amount and a uint256 Unix time value into a uint64
     * @param _tokenAmount is the input token amount to be encoded
     * @param _unixTime is the input unix time value to be encoded
     * @return is the uint64 encoded data
     * @dev This function uses bit shifting and bitwise operations to encode the data.
            This function shifts the token amount value left by 32 bits,
            which effectively multiplies it by 2^32, and then ORs it with the unix time
            value using the | operator.
     */
    function _encodeTradeData(uint256 _tokenAmount, uint256 _unixTime) public pure returns (uint64) {
      // Shift the token amount left by 32 bits and OR it with the unix time value
      return (uint64(_tokenAmount) << 32) | uint64(_unixTime);
    }

    /**
     * @notice decodes a uint64 into its original token amount and Unix time value
     * @param encoded is the uint64 encoded data for a token amount and a unix time stamp
     * @return td is the decoded token and unix timestamp data both in uint256 stored in a tradeData struct
     * @dev This function uses bit shifting and bitwise operations to decode the data.
            This function shifts the encoded value right by 32 bits using the >> operator
            to get the original token amount, and ANDs it with 0xffffffff using the & operator
            to get the original unix time value.
     */
     function _decodeTradeData(uint64 encoded) public pure returns (TradeData memory td) {
       // Shift the encoded value right by 32 bits to get the token amount, and AND it with 2^32 - 1 to get the unix time value
         td.minReturnAmount = uint256(encoded >> 32);
         td.deadline = encoded & 0xffffffff;
     }

     /**
      * @notice Computes the criteria that is passed when claiming subsidy.
      * @param _inputAssetA The input asset
      * @param _outputAssetA The output asset
      * @return The criteria
      */
     function computeCriteria(
         AztecTypes.AztecAsset calldata _inputAssetA,
         AztecTypes.AztecAsset calldata,
         AztecTypes.AztecAsset calldata _outputAssetA,
         AztecTypes.AztecAsset calldata,
         uint64
     ) public view override (BridgeBase) returns (uint256) {
         return uint256(keccak256(abi.encodePacked(_inputAssetA.erc20Address, _outputAssetA.erc20Address)));
     }

}
