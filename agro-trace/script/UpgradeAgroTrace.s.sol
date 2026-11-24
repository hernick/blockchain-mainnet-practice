// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {AgroTrace} from "../src/AgroTrace.sol";

/// @title UpgradeAgroTrace - Despliega una nueva implementación y actualiza el proxy (UUPS)
/// @notice Reemplazá `new AgroTrace()` por tu versión nueva (ej: AgroTraceV2) antes de correrlo.
///   source .env
///   forge script script/UpgradeAgroTrace.s.sol:UpgradeAgroTrace --rpc-url sepolia --broadcast --verify -vvvv
/// @dev La wallet de PRIVATE_KEY debe tener UPGRADER_ROLE. Antes de un upgrade real, validá el layout de
///      storage (ver README: openzeppelin-foundry-upgrades o `forge inspect ... storageLayout`).
contract UpgradeAgroTrace is Script {
    function run() external returns (address newImplementation) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("PROXY_ADDRESS");

        vm.startBroadcast(key);
        newImplementation = address(new AgroTrace()); // <- cambiar por la nueva versión
        AgroTrace(proxy).upgradeToAndCall(newImplementation, "");
        vm.stopBroadcast();

        console2.log("Nueva implementacion:", newImplementation);
        console2.log("Version actual:", AgroTrace(proxy).version());
    }
}
