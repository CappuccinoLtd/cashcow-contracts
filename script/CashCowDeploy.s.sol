// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CREATE3Factory} from "create3-factory/src/CREATE3Factory.sol";
import {CashCow} from "../src/CashCow.sol";

contract CashCowDeployScript is Script {
    bytes32 salt = keccak256(abi.encodePacked(vm.envString("SALT")));
    address owner = vm.envAddress("OWNER");
    uint256 ownerPrivateKey = vm.envUint("OWNER_PRIVATE_KEY");
    address create3Factory = vm.envAddress("CREATE3_FACTORY");

    function run() external {
        vm.startBroadcast(ownerPrivateKey);

        CREATE3Factory factory;
        if (create3Factory == address(0)) {
            console2.log("Deploying create3 factory...");
            factory = new CREATE3Factory{salt: salt}();
            console2.log("Create3 factory deployed: ", address(factory));
        } else {
            console2.log("Reusing existing create3 factory");
            factory = CREATE3Factory(create3Factory);
        }

        console2.log("Deploying CashCow...");
        address contractAddr = factory.deploy(salt, abi.encodePacked(type(CashCow).creationCode, abi.encode(owner)));
        console2.log("CashCow deployed: ", contractAddr);

        vm.stopBroadcast();
    }
}
