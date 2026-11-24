// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgroTrace} from "../src/AgroTrace.sol";

/// @title DeployAgroTrace - Despliega implementación + ERC1967Proxy e inicializa en la misma tx del proxy
/// @notice Uso (Sepolia):
///   source .env
///   forge script script/DeployAgroTrace.s.sol:DeployAgroTrace \
///     --rpc-url sepolia --broadcast --verify -vvvv
/// @dev Inicializar dentro del constructor del proxy evita el ataque de "front-running" del initialize.
contract DeployAgroTrace is Script {
    function run() external returns (AgroTrace agro, address implementation) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        // ADMIN_ADDRESS es opcional; por defecto, la propia wallet que despliega.
        address admin = vm.envOr("ADMIN_ADDRESS", deployer);

        vm.startBroadcast(deployerKey);

        implementation = address(new AgroTrace());
        bytes memory initData = abi.encodeCall(AgroTrace.initialize, (admin));
        ERC1967Proxy proxy = new ERC1967Proxy(implementation, initData);
        agro = AgroTrace(address(proxy));

        vm.stopBroadcast();

        console2.log("Implementacion AgroTrace:", implementation);
        console2.log("Proxy (direccion a usar):", address(proxy));
        console2.log("Admin:", admin);
        console2.log("Version:", agro.version());
    }
}
