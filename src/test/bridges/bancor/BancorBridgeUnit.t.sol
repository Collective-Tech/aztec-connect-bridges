// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec.
pragma solidity >=0.8.4;

import {BridgeTestBase} from "./../../aztec/base/BridgeTestBase.sol";
import {AztecTypes} from "rollup-encoder/libraries/AztecTypes.sol";

// Example-specific imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BancorBridge} from "../../../bridges/bancor/BancorBridge.sol";
import {ErrorLib} from "../../../bridges/base/ErrorLib.sol";

// @notice The purpose of this test is to directly test convert functionality of the bridge.
contract BancorBridgeUnitTest is BridgeTestBase {
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant BENEFICIARY = address(11);

    address private rollupProcessor;
    // The reference to the example bridge
    BancorBridge private bridge;

    struct TradeData {
      uint256 minReturnAmount;
      uint256 deadline;
    }

    function setUp() public {
        uint256[] memory criterias = new uint256[](2);
        uint32[] memory gasUsage = new uint32[](2);
        uint32[] memory minGasPerMinute = new uint32[](2);

        criterias[0] = uint256(keccak256(abi.encodePacked(DAI, USDC)));
        criterias[1] = uint256(keccak256(abi.encodePacked(USDC, DAI)));

        gasUsage[0] = 72896;
        gasUsage[1] = 80249;

        minGasPerMinute[0] = 100;
        minGasPerMinute[1] = 150;



        // In unit tests we set address of rollupProcessor to the address of this test contract
        rollupProcessor = address(this);

        // Deploy a new example bridge
        bridge = new BancorBridge(rollupProcessor, criterias, gasUsage, minGasPerMinute);
        vm.startPrank(MULTI_SIG);
        ROLLUP_PROCESSOR.setSupportedBridge(address(bridge), 1500000);
        ROLLUP_PROCESSOR.setSupportedAsset(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 55000); // USDC
        vm.stopPrank();

        // Set ETH balance of bridge and BENEFICIARY to 0 for clarity (somebody sent ETH to that address on mainnet)
        vm.deal(address(bridge), 0);
        vm.deal(BENEFICIARY, 0);

        // Use the label cheatcode to mark the address with "Bancor Bridge" in the traces
        vm.label(address(bridge), "Bancor Bridge");

        // Subsidize the bridge when used with Dai and register a beneficiary
        AztecTypes.AztecAsset memory usdcAsset = ROLLUP_ENCODER.getRealAztecAsset(USDC);
        AztecTypes.AztecAsset memory daiAsset = ROLLUP_ENCODER.getRealAztecAsset(DAI);

        uint256 criteria = bridge.computeCriteria(daiAsset, emptyAsset, usdcAsset, emptyAsset, 0);
        uint32 gasPerMinute = 200;
        SUBSIDY.subsidize{value: 1 ether}(address(bridge), criteria, gasPerMinute);

        SUBSIDY.registerBeneficiary(BENEFICIARY);
    }

    function testInvalidCaller(address _callerAddress) public {
        vm.assume(_callerAddress != rollupProcessor);
        // Use HEVM cheatcode to call from a different address than is address(this)
        vm.prank(_callerAddress);
        vm.expectRevert(ErrorLib.InvalidCaller.selector);
        bridge.convert(emptyAsset, emptyAsset, emptyAsset, emptyAsset, 0, 0, 0, address(0));
    }

    function testInvalidInputAssetType() public {
        vm.expectRevert(ErrorLib.InvalidInputA.selector);
        bridge.convert(emptyAsset, emptyAsset, emptyAsset, emptyAsset, 0, 0, 0, address(0));
    }

    function testInvalidOutputAssetType() public {
        AztecTypes.AztecAsset memory inputAssetA =
            AztecTypes.AztecAsset({id: 1, erc20Address: DAI, assetType: AztecTypes.AztecAssetType.ERC20});
        vm.expectRevert(ErrorLib.InvalidOutputA.selector);
        bridge.convert(inputAssetA, emptyAsset, emptyAsset, emptyAsset, 0, 0, 0, address(0));
    }

    function testEncoding() public {
        uint32 currentTime = uint32(block.timestamp);
        uint256 minimumPriceData = 5;
        uint256 expectedReturnPriceData = minimumPriceData * 1e14;
        uint256 expectedUSDCReturnPriceData = minimumPriceData * 1e6;
        uint64 encodedData = bridge.encodeTradeData(minimumPriceData, currentTime);
        uint256 returnedMinAmount = bridge.decodeTradeData(encodedData).minReturnAmount;
        uint256 returnedDeadline = bridge.decodeTradeData(encodedData).deadline;
        assertEq(returnedMinAmount, expectedReturnPriceData, "Decoded minimum price data does not match");
        assertEq(returnedDeadline, currentTime, "Decoded deadline time data does not match");
        uint256 returnedMinAmountUSDC = bridge.decodeTradeDataUSDC(encodedData).minReturnAmount;
        uint256 returnedDeadlineUSDC = bridge.decodeTradeDataUSDC(encodedData).deadline;
        assertEq(returnedMinAmountUSDC, expectedUSDCReturnPriceData, "Decoded minimum USDC price data does not match");
        assertEq(returnedDeadlineUSDC, currentTime, "Decoded deadline timeUSDC data does not match");
    }

    function testExampleBridgeUnitTestFixed() public {
        testExampleBridgeUnitTest(10);
    }

    // function testExampleBridgeUnitTestUSDCFixed() public {
    //     testExampleBridgeUnitTestUSDC(10);
    // }

    // @notice The purpose of this test is to directly test convert functionality of the bridge.
    // @dev In order to avoid overflows we set _depositAmount to be uint96 instead of uint256.
    function testExampleBridgeUnitTest(uint96 _depositAmount) public {
        vm.warp(block.timestamp + 1 days);

        // Define input and output assets
        AztecTypes.AztecAsset memory inputAssetA =
            AztecTypes.AztecAsset({id: 1, erc20Address: USDC, assetType: AztecTypes.AztecAssetType.ERC20});

        AztecTypes.AztecAsset memory outputAssetA =
            AztecTypes.AztecAsset({id: 2, erc20Address: DAI, assetType: AztecTypes.AztecAssetType.ERC20});

        // Rollup processor transfers ERC20 tokens to the bridge before calling convert. Since we are calling
        // bridge.convert(...) function directly we have to transfer the funds in the test on our own. In this case
        // we'll solve it by directly minting the _depositAmount of Dai to the bridge.
        deal(USDC, address(bridge), _depositAmount);

        // set up approvals for tokens on all sides
                {
                    address[] memory tokensIn = new address[](2);
                    tokensIn[0] = USDC;
                    tokensIn[1] = DAI;


                    address[] memory tokensOut = new address[](2);
                    tokensOut[0] = USDC;
                    tokensOut[1] = DAI;


                    bridge.preApproveTokens(tokensIn, tokensOut);
                }

        // Store dai balance before interaction to be able to verify the balance after interaction is correct
        uint256 daiBalanceBefore = IERC20(DAI).balanceOf(rollupProcessor);

        uint32 currentTime = uint32(block.timestamp) + 10000;
        uint256 minimumPriceData = _depositAmount;
        uint64 encodedData = bridge.encodeTradeData(minimumPriceData, currentTime);


        (uint256 outputValueA, uint256 outputValueB, bool isAsync) = bridge.convert(
            inputAssetA, // _inputAssetA - definition of an input asset
            emptyAsset, // _inputAssetB - not used so can be left empty
            outputAssetA, // _outputAssetA - in this example equal to input asset
            emptyAsset, // _outputAssetB - not used so can be left empty
            _depositAmount, // _totalInputValue - an amount of input asset A sent to the bridge
            1, // _interactionNonce
            encodedData, // _auxData - not used in the example bridge
            BENEFICIARY // _rollupBeneficiary - address, the subsidy will be sent to
        );
        //
        // // Now we transfer the funds back from the bridge to the rollup processor
        // // In this case input asset equals output asset so I only work with the input asset definition
        // // Basically in all the real world use-cases output assets would differ from input assets
        // IERC20(inputAssetA.erc20Address).transferFrom(address(bridge), rollupProcessor, outputValueA);
        //
        // assertEq(outputValueA, _depositAmount, "Output value A doesn't equal deposit amount");
        // assertEq(outputValueB, 0, "Output value B is not 0");
        // assertTrue(!isAsync, "Bridge is incorrectly in an async mode");
        //
        // uint256 daiBalanceAfter = IERC20(DAI).balanceOf(rollupProcessor);
        //
        // assertEq(daiBalanceAfter - daiBalanceBefore, _depositAmount, "Balances must match");
        //
        // SUBSIDY.withdraw(BENEFICIARY);
        // assertGt(BENEFICIARY.balance, 0, "Subsidy was not claimed");
    }

    // // @notice The purpose of this test is to directly test convert functionality of the bridge.
    // // @dev In order to avoid overflows we set _depositAmount to be uint96 instead of uint256.
    // function testExampleBridgeUnitTestUSDC(uint96 _depositAmount) public {
    //     vm.warp(block.timestamp + 1 days);
    //
    //     // Define input and output assets
    //     AztecTypes.AztecAsset memory inputAssetA =
    //         AztecTypes.AztecAsset({id: 1, erc20Address: DAI, assetType: AztecTypes.AztecAssetType.ERC20});
    //
    //     AztecTypes.AztecAsset memory outputAssetA =
    //         AztecTypes.AztecAsset({id: 1, erc20Address: USDC, assetType: AztecTypes.AztecAssetType.ERC20});
    //
    //     // Rollup processor transfers ERC20 tokens to the bridge before calling convert. Since we are calling
    //     // bridge.convert(...) function directly we have to transfer the funds in the test on our own. In this case
    //     // we'll solve it by directly minting the _depositAmount of Dai to the bridge.
    //     deal(DAI, address(bridge), _depositAmount);
    //
    //     // Store dai balance before interaction to be able to verify the balance after interaction is correct
    //     uint256 daiBalanceBefore = IERC20(DAI).balanceOf(rollupProcessor);
    //
    //     (uint256 outputValueA, uint256 outputValueB, bool isAsync) = bridge.convert(
    //         inputAssetA, // _inputAssetA - definition of an input asset
    //         emptyAsset, // _inputAssetB - not used so can be left empty
    //         outputAssetA, // _outputAssetA - in this example equal to input asset
    //         emptyAsset, // _outputAssetB - not used so can be left empty
    //         _depositAmount, // _totalInputValue - an amount of input asset A sent to the bridge
    //         0, // _interactionNonce
    //         0, // _auxData - not used in the example bridge
    //         BENEFICIARY // _rollupBeneficiary - address, the subsidy will be sent to
    //     );
    //
    //     // Now we transfer the funds back from the bridge to the rollup processor
    //     // In this case input asset equals output asset so I only work with the input asset definition
    //     // Basically in all the real world use-cases output assets would differ from input assets
    //     IERC20(inputAssetA.erc20Address).transferFrom(address(bridge), rollupProcessor, outputValueA);
    //
    //     assertEq(outputValueA, _depositAmount, "Output value A doesn't equal deposit amount");
    //     assertEq(outputValueB, 0, "Output value B is not 0");
    //     assertTrue(!isAsync, "Bridge is incorrectly in an async mode");
    //
    //     uint256 daiBalanceAfter = IERC20(DAI).balanceOf(rollupProcessor);
    //
    //     assertEq(daiBalanceAfter - daiBalanceBefore, _depositAmount, "Balances must match");
    //
    //     SUBSIDY.withdraw(BENEFICIARY);
    //     assertGt(BENEFICIARY.balance, 0, "Subsidy was not claimed");
    // }
}
