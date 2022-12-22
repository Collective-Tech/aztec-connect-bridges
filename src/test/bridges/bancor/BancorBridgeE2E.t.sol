// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec.
pragma solidity >=0.8.4;

import {BridgeTestBase} from "./../../aztec/base/BridgeTestBase.sol";
import {AztecTypes} from "rollup-encoder/libraries/AztecTypes.sol";

// Example-specific imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BancorBridge} from "../../../bridges/bancor/BancorBridge.sol";
import {ErrorLib} from "../../../bridges/base/ErrorLib.sol";

/**
 * @notice The purpose of this test is to test the bancor bridge in an environment that is as close to the final deployment
 *         as possible without spinning up all the rollup infrastructure (sequencer, proof generator etc.).
 */
contract BancorBridgeE2ETest is BridgeTestBase {
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address private constant BENEFICIARY = address(11);

    // The reference to the bancor bridge
    BancorBridge internal bridge;
    // To store the id of the bancor bridge after being added
    uint256 private id;

    function setUp() public {
        // Deploy a new example bridge
        bridge = new BancorBridge(address(ROLLUP_PROCESSOR));
        // Use the label to mark the bridge address with "Bancor Bridge" in the traces
        vm.label(address(bridge), "Bancor Bridge");
        // Use the label to mark the Bancor Network contract address with "Bancor network" in the traces
        vm.label(address(bridge.BANCOR()), "Bancor Network");
        // Use the label to mark the DAI and USDC contracts with their re4spective names in the traces
        vm.label(DAI, "DAI");
        vm.label(USDC, "USDC");

        // Impersonate the multi-sig to add a new bridge
        vm.startPrank(MULTI_SIG);

        // List the example-bridge with a gasLimit of 120k
        // WARNING: If you set this value too low the interaction will fail for seemingly no reason!
        // OTOH if you see it too high bridge users will pay too much
        ROLLUP_PROCESSOR.setSupportedBridge(address(bridge), 120000);

        // List USDC and DAI with a gasLimit of 100k
        // Note: necessary for assets which are not already registered on RollupProcessor
        // Call https://etherscan.io/address/0xFF1F2B4ADb9dF6FC8eAFecDcbF96A2B351680455#readProxyContract#F25 to get
        // addresses of all the listed ERC20 tokens
        ROLLUP_PROCESSOR.setSupportedAsset(USDC, 100000);
        ROLLUP_PROCESSOR.setSupportedAsset(DAI, 100000);

        vm.stopPrank();

        // Fetch the id of the example bridge
        id = ROLLUP_PROCESSOR.getSupportedBridgesLength();

        // Subsidize the bridge when used with USDC and DAI and register a beneficiary
        AztecTypes.AztecAsset memory usdcAsset = ROLLUP_ENCODER.getRealAztecAsset(USDC);
        AztecTypes.AztecAsset memory daiAsset = ROLLUP_ENCODER.getRealAztecAsset(DAI);

        uint256 criteria = bridge.computeCriteria(usdcAsset, daiAsset, usdcAsset, daiAsset, 0);
        uint32 gasPerMinute = 200;
        SUBSIDY.subsidize{value: 1 ether}(address(bridge), criteria, gasPerMinute);

        SUBSIDY.registerBeneficiary(BENEFICIARY);

        // Set the rollupBeneficiary on BridgeTestBase so that it gets included in the proofData
        ROLLUP_ENCODER.setRollupBeneficiary(BENEFICIARY);
    }

    // @dev In order to avoid overflows we set _depositAmount to be uint96 instead of uint256.
    function testBancorBridgeE2ETest(uint96 _depositAmount) public {
        vm.assume(_depositAmount > 1);
        vm.warp(block.timestamp + 1 days);

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

        // Use the helper function to fetch the support AztecAssets for USDC and DAI
        AztecTypes.AztecAsset memory usdcAsset = ROLLUP_ENCODER.getRealAztecAsset(address(USDC));
        AztecTypes.AztecAsset memory daiAsset = ROLLUP_ENCODER.getRealAztecAsset(address(DAI));

        // Mint the depositAmount of Dai to rollupProcessor
        deal(USDC, address(ROLLUP_PROCESSOR), _depositAmount);

        // Computes the encoded data for the specific bridge interaction
        ROLLUP_ENCODER.defiInteractionL2(id, usdcAsset, emptyAsset, daiAsset, emptyAsset, 0, _depositAmount);

        // Execute the rollup with the bridge interaction. Ensure that event as seen above is emitted.
        (uint256 outputValueA, uint256 outputValueB, bool isAsync) = ROLLUP_ENCODER.processRollupAndGetBridgeResult();

        // Note: Unlike in unit tests there is no need to manually transfer the tokens - RollupProcessor does this
        // Check the output values are as expected
        assertEq(outputValueA, _depositAmount, "outputValueA doesn't equal deposit");
        assertEq(outputValueB, 0, "Non-zero outputValueB");
        assertFalse(isAsync, "Bridge is not synchronous");

        // Check that the balance of the rollup is same as before interaction (bridge just sends funds back)
        assertEq(_depositAmount, IERC20(USDC).balanceOf(address(ROLLUP_PROCESSOR)), "Balances must match");

        // Perform a second rollup with half the deposit, perform similar checks.
        uint256 secondDeposit = _depositAmount / 2;

        ROLLUP_ENCODER.defiInteractionL2(id, usdcAsset, emptyAsset, daiAsset, emptyAsset, 0, secondDeposit);

        // Execute the rollup with the bridge interaction. Ensure that event as seen above is emitted.
        (outputValueA, outputValueB, isAsync) = ROLLUP_ENCODER.processRollupAndGetBridgeResult();

        // Check the output values are as expected
        assertEq(outputValueA, secondDeposit, "outputValueA doesn't equal second deposit");
        assertEq(outputValueB, 0, "Non-zero outputValueB");
        assertFalse(isAsync, "Bridge is not synchronous");

        // Check that the balance of the rollup is same as before interaction (bridge just sends funds back)
        assertEq(_depositAmount, IERC20(USDC).balanceOf(address(ROLLUP_PROCESSOR)), "Balances must match");

        assertGt(SUBSIDY.claimableAmount(BENEFICIARY), 0, "Claimable was not updated");
    }


}
