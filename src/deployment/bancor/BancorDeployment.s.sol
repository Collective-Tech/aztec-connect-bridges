// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec.
pragma solidity >=0.8.4;

import {BaseDeployment} from "../base/BaseDeployment.s.sol";
import {BancorBridge} from "../../bridges/bancor/BancorBridge.sol";

contract ExampleDeployment is BaseDeployment {
    function deploy() public returns (address) {
        emit log("Deploying Bancor bridge");
        address dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        uint256[] memory criterias = new uint256[](2);
        uint32[] memory gasUsage = new uint32[](2);
        uint32[] memory minGasPerMinute = new uint32[](2);

        criterias[0] = uint256(keccak256(abi.encodePacked(dai, usdc)));
        criterias[1] = uint256(keccak256(abi.encodePacked(usdc, dai)));

        gasUsage[0] = 72896;
        gasUsage[1] = 80249;

        minGasPerMinute[0] = 100;
        minGasPerMinute[1] = 150;

        vm.broadcast();
        BancorBridge bridge = new BancorBridge(ROLLUP_PROCESSOR, criterias, gasUsage, minGasPerMinute);

        emit log_named_address("Bancor bridge deployed to", address(bridge));

        return address(bridge);
    }

    function deployAndList() public {
        address bridge = deploy();
        uint256 addressId = listBridge(bridge, 250000);
        emit log_named_uint("Example bridge address id", addressId);
    }
}
