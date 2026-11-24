// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {AgroTrace} from "../src/AgroTrace.sol";
import {AgroGovernor} from "../src/governance/AgroGovernor.sol";

/// @title ProposeUpgrade - Upgrade de AgroTrace a través de la DAO (propose / queue / execute)
/// @notice Después del traspaso a gobernanza, NINGUNA wallet puede llamar `upgradeToAndCall` directo:
///         solo el Timelock, cuando una propuesta fue aprobada y pasó la demora.
///
///   source .env   # PRIVATE_KEY, GOVERNOR_ADDRESS, PROXY_ADDRESS
///
///   # 1) Desplegar la nueva implementación y crear la propuesta (imprime NEW_IMPLEMENTATION y proposalId)
///   forge script script/ProposeUpgrade.s.sol:ProposeUpgrade --rpc-url sepolia --broadcast -vvvv
///
///   # 2) Votar (cualquier holder con votos delegados), después de votingDelay bloques:
///   cast send $GOVERNOR_ADDRESS "castVote(uint256,uint8)" <proposalId> 1 --rpc-url sepolia --private-key $PRIVATE_KEY
///
///   # 3) Cuando termina la votación y la propuesta está Succeeded (state == 4), encolar en el Timelock:
///   NEW_IMPLEMENTATION=0x... forge script script/ProposeUpgrade.s.sol:ProposeUpgrade \
///     --sig "queue()" --rpc-url sepolia --broadcast
///
///   # 4) Pasado TIMELOCK_MIN_DELAY, ejecutar (cualquiera puede):
///   NEW_IMPLEMENTATION=0x... forge script script/ProposeUpgrade.s.sol:ProposeUpgrade \
///     --sig "execute()" --rpc-url sepolia --broadcast
///
/// @dev queue/execute recalculan la propuesta con los MISMOS targets, calldatas y descripción: por eso
///      PROPOSAL_DESCRIPTION tiene que ser idéntica en los tres pasos (su hash forma parte del proposalId).
contract ProposeUpgrade is Script {
    string internal constant DEFAULT_DESCRIPTION = "AGP-1: upgrade de la implementacion de AgroTrace";

    /// @notice Paso 1: despliega la nueva implementación (o usa NEW_IMPLEMENTATION) y la propone.
    function run() external returns (uint256 proposalId, address newImplementation) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        AgroGovernor governor = AgroGovernor(payable(vm.envAddress("GOVERNOR_ADDRESS")));
        address proxy = vm.envAddress("PROXY_ADDRESS");
        newImplementation = vm.envOr("NEW_IMPLEMENTATION", address(0));

        vm.startBroadcast(key);
        if (newImplementation == address(0)) {
            newImplementation = address(new AgroTrace()); // <- cambiar por la nueva versión (ej.: AgroTraceV2)
        }
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _proposal(proxy, newImplementation);
        proposalId = governor.propose(targets, values, calldatas, _description());
        vm.stopBroadcast();

        console2.log("NEW_IMPLEMENTATION:", newImplementation);
        console2.log("proposalId:");
        console2.log(proposalId);
        console2.log("Votacion desde el bloque:", governor.proposalSnapshot(proposalId) + 1);
        console2.log("Votacion hasta el bloque:", governor.proposalDeadline(proposalId));
    }

    /// @notice Paso 3: encola la propuesta aprobada en el Timelock.
    function queue() external {
        (AgroGovernor governor, address[] memory t, uint256[] memory v, bytes[] memory c) = _load();
        vm.broadcast(vm.envUint("PRIVATE_KEY"));
        uint256 proposalId = governor.queue(t, v, c, keccak256(bytes(_description())));
        console2.log("Encolada. ETA (timestamp):", governor.proposalEta(proposalId));
    }

    /// @notice Paso 4: ejecuta la propuesta cuando venció la demora del Timelock.
    function execute() external {
        (AgroGovernor governor, address[] memory t, uint256[] memory v, bytes[] memory c) = _load();
        vm.broadcast(vm.envUint("PRIVATE_KEY"));
        governor.execute(t, v, c, keccak256(bytes(_description())));
        console2.log("Ejecutada. Version actual:", AgroTrace(t[0]).version());
    }

    function _load() internal view returns (AgroGovernor governor, address[] memory, uint256[] memory, bytes[] memory) {
        governor = AgroGovernor(payable(vm.envAddress("GOVERNOR_ADDRESS")));
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _proposal(vm.envAddress("PROXY_ADDRESS"), vm.envAddress("NEW_IMPLEMENTATION"));
        return (governor, t, v, c);
    }

    /// @dev Una sola acción: proxy.upgradeToAndCall(newImplementation, "").
    function _proposal(address proxy, address newImplementation)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = proxy;
        calldatas[0] = abi.encodeCall(AgroTrace(proxy).upgradeToAndCall, (newImplementation, ""));
    }

    function _description() internal view returns (string memory) {
        return vm.envOr("PROPOSAL_DESCRIPTION", DEFAULT_DESCRIPTION);
    }
}
