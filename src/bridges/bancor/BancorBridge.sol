// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec
pragma solidity >=0.8.4;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
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
    using SafeMath for uint;

    struct TradeData {
      uint256 minReturnAmount;
      uint256 deadline;
    }


    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // @dev Event which is emitted when the output token doesn't implement decimals().

    IBancorNetwork public constant BANCOR = IBancorNetwork(0xeEF417e1D5CC832e619ae18D2F140De2999dD4fB);


    /**
     * @notice Set the address of rollup processor.
     * @param _rollupProcessor Address of rollup processor
     */
    constructor(
      address _rollupProcessor,
      uint256[] memory criterias,
      uint32[] memory gasUsage,
      uint32[] memory minGasPerMinute
    ) BridgeBase(_rollupProcessor) {
      // We set gas usage in the subsidy contract
      SUBSIDY.setGasUsageAndMinGasPerMinute(criterias, gasUsage, minGasPerMinute);
    }

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
        TradeData memory td;

        // check if output asset is USDC or a normal ie18 decimal place token
          if(_outputAssetA.erc20Address == USDC) {
            td = decodeTradeDataUSDC(_auxData);
          } else {
            td = decodeTradeData(_auxData);
          }

            // Swap using the first swap path
            outputValueA = BANCOR.tradeBySourceAmount(
              iT,
              oT,
              _totalInputValue,
              td.minReturnAmount,
              td.deadline,
              address(this)
            );

            if (outputIsEth) {
                IWETH(WETH).withdraw(outputValueA);
                IRollupProcessor(ROLLUP_PROCESSOR).receiveEthFromBridge{value: outputValueA}(_interactionNonce);
            }

            return (outputValueA, 0, false);
    }


    /**
     * @notice encodes a uint256 token amount and a uint256 Unix time value into a uint64
     * @param _tokenAmount is the input token amount to be encoded
     * @param _unixTimestamp is the input unix time value to be encoded
     * @return is the uint64 encoded data
     * @dev This function uses bit shifting and bitwise operations to encode the data.
            This function shifts the token amount value left by 32 bits,
            which effectively multiplies it by 2^32, and then ORs it with the unix time
            value using the | operator.
     * @dev Token amount values are limited to encoding 9 digits which means that a full 1e18 number
            would be encoded as 10000. The decode function expectss a 1e14 transform on the decoded number
            allowing for a maximum input token value of 99999.999900000000000000 and a minimum token value of
            0.000100000000000000 assuming the token decimals are 18
     * @dev there is a special decode function for use with USDC that assumes a 1e6 decimal format when
            decoding USDC values making the max amount of USDC 999999999 and the minimum 1
     */
     function encodeTradeData(uint256 _tokenAmount, uint32 _unixTimestamp) public pure returns (uint64) {
       // Shift the token amount 32 bits to the left
       uint64 value1_64 = uint64(_tokenAmount) << 32;
       // OR the Unix timestamp with the token amount
       return value1_64 | uint64(_unixTimestamp);
     }

    /**
     * @notice decodes a uint64 into its original token amount and Unix time value
     * @param _encoded is the uint64 encoded data for a token amount and a unix time stamp
     * @return td is the decoded token and unix timestamp data both in uint256 stored in a tradeData struct
     * @dev This function uses bit shifting and bitwise operations to decode the data.
            This function shifts the encoded value right by 32 bits using the >> operator
            to get the original token amount, and ANDs it with 0xffffffff using the & operator
            to get the original unix time value.
     * @dev this decode function is used with normal tokens who have a 1e18 decimal place value
     */
     function decodeTradeData(uint64 _encoded) public pure returns (TradeData memory td) {
         // Shift the encoded value right by 32 bits to get the token amount
         uint256 preTokenVal = uint256(_encoded >> 32);
         td.minReturnAmount = preTokenVal * 1e14;
         // AND the encoded value with 2^32 - 1 to get the Unix timestamp
         td.deadline = uint32(_encoded & (2 ** 32 - 1));
     }

     /**
      * @notice decodes a uint64 into its original token amount and Unix time value
      * @param _encoded is the uint64 encoded data for a token amount and a unix time stamp
      * @return td is the decoded token and unix timestamp data both in uint256 stored in a tradeData struct
      * @dev This function uses bit shifting and bitwise operations to decode the data.
             This function shifts the encoded value right by 32 bits using the >> operator
             to get the original token amount, and ANDs it with 0xffffffff using the & operator
             to get the original unix time value.
      * @dev this decode function is exclusivly with USDC which has a 6 place decimal value
      */
      function decodeTradeDataUSDC(uint64 _encoded) public pure returns (TradeData memory td) {
          // Shift the encoded value right by 32 bits to get the token amount
          uint256 preTokenVal = uint256(_encoded >> 32);
          td.minReturnAmount = preTokenVal * 1e6;
          // AND the encoded value with 2^32 - 1 to get the Unix timestamp
          td.deadline = uint32(_encoded & (2 ** 32 - 1));
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
     ) public pure override (BridgeBase) returns (uint256) {
         return uint256(keccak256(abi.encodePacked(_inputAssetA.erc20Address, _outputAssetA.erc20Address)));
     }

}
