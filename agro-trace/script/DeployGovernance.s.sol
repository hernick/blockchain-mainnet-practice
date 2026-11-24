// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {AgroTrace} from "../src/AgroTrace.sol";
import {AgroGovToken} from "../src/governance/AgroGovToken.sol";
import {AgroGovernor} from "../src/governance/AgroGovernor.sol";

/// @title DeployGovernance - Despliega token + Timelock + Governor y le entrega AgroTrace a la DAO
/// @notice Uso (Sepolia):
///   source .env
///   forge script script/DeployGovernance.s.sol:DeployGovernance --rpc-url sepolia --broadcast --verify -vvvv
///
/// Variables de entorno (todas opcionales salvo PRIVATE_KEY):
///   PROXY_ADDRESS        Proxy de AgroTrace ya desplegado (la wallet debe ser su admin).
///                        Si no se define, se despliega un AgroTrace nuevo (implementación + proxy).
///   TOKEN_RECIPIENT      Quién recibe el suministro de AGT (default: deployer).
///   TOKEN_SUPPLY         Suministro inicial en wei de AGT (default: 1.000.000 AGT).
///   VOTING_DELAY         Bloques hasta que arranca la votación (default: 1).
///   VOTING_PERIOD        Bloques que dura la votación (default: 50400 ≈ 7 días con bloques de 12 s).
///   PROPOSAL_THRESHOLD   Votos mínimos para proponer, en wei de AGT (default: 0).
///   QUORUM_PERCENT       Quórum en % del suministro (default: 4).
///   TIMELOCK_MIN_DELAY   Demora mínima del Timelock en segundos (default: 86400 = 1 día).
///
/// @dev Pasos (todos en el mismo broadcast):
///   1. (opcional) AgroTrace implementación + ERC1967Proxy, con el deployer como admin temporal.
///   2. AgroGovToken y auto-delegación del deployer si es el receptor (sin delegar no hay votos).
///   3. TimelockController con el deployer como admin TEMPORAL y ejecución abierta (address(0)).
///   4. AgroGovernor, que recibe PROPOSER_ROLE y CANCELLER_ROLE en el Timelock.
///   5. El Timelock recibe DEFAULT_ADMIN_ROLE y UPGRADER_ROLE de AgroTrace.
///   6. El deployer renuncia a sus roles en AgroTrace y al admin del Timelock.
///   7. Se verifican las post-condiciones; si algo no cuadra, el script revierte.
contract DeployGovernance is Script {
    struct Config {
        address agroProxy; // address(0) = desplegar un AgroTrace nuevo
        address tokenRecipient;
        uint256 tokenSupply;
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumPercent;
        uint256 timelockMinDelay;
    }

    struct Deployment {
        AgroTrace agro;
        AgroGovToken token;
        TimelockController timelock;
        AgroGovernor governor;
    }

    error DeployerIsNotAgroAdmin(address deployer);
    error HandoverFailed(string what);

    function run() external returns (Deployment memory d) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        Config memory cfg = loadConfig(deployer);

        vm.startBroadcast(deployerKey);
        d = _deploy(cfg, deployer);
        vm.stopBroadcast();

        _checkHandover(d, deployer);
        _log(d, cfg);
    }

    /// @notice Lee los parámetros desde variables de entorno, con defaults pensados para Sepolia.
    function loadConfig(address deployer) public view returns (Config memory cfg) {
        cfg.agroProxy = vm.envOr("PROXY_ADDRESS", address(0));
        cfg.tokenRecipient = vm.envOr("TOKEN_RECIPIENT", deployer);
        cfg.tokenSupply = vm.envOr("TOKEN_SUPPLY", uint256(1_000_000 ether));
        cfg.votingDelay = uint48(vm.envOr("VOTING_DELAY", uint256(1)));
        cfg.votingPeriod = uint32(vm.envOr("VOTING_PERIOD", uint256(50_400)));
        cfg.proposalThreshold = vm.envOr("PROPOSAL_THRESHOLD", uint256(0));
        cfg.quorumPercent = vm.envOr("QUORUM_PERCENT", uint256(4));
        cfg.timelockMinDelay = vm.envOr("TIMELOCK_MIN_DELAY", uint256(1 days));
    }

    function _deploy(Config memory cfg, address deployer) internal returns (Deployment memory d) {
        // 1. AgroTrace: reutiliza el proxy existente o despliega uno nuevo.
        if (cfg.agroProxy == address(0)) {
            address impl = address(new AgroTrace());
            d.agro = AgroTrace(address(new ERC1967Proxy(impl, abi.encodeCall(AgroTrace.initialize, (deployer)))));
        } else {
            d.agro = AgroTrace(cfg.agroProxy);
        }
        if (!d.agro.hasRole(d.agro.DEFAULT_ADMIN_ROLE(), deployer)) revert DeployerIsNotAgroAdmin(deployer);

        // 2. Token de votos. Sin delegar, el saldo no cuenta como voto.
        d.token = new AgroGovToken(cfg.tokenRecipient, cfg.tokenSupply);
        if (cfg.tokenRecipient == deployer) d.token.delegate(deployer);

        // 3. Timelock: sin proposers todavía (el Governor no existe), ejecución abierta a cualquiera.
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1); // executors[0] = address(0) -> cualquiera ejecuta
        d.timelock = new TimelockController(cfg.timelockMinDelay, proposers, executors, deployer);

        // 4. Governor + roles en el Timelock.
        d.governor = new AgroGovernor(
            d.token, d.timelock, cfg.votingDelay, cfg.votingPeriod, cfg.proposalThreshold, cfg.quorumPercent
        );
        d.timelock.grantRole(d.timelock.PROPOSER_ROLE(), address(d.governor));
        d.timelock.grantRole(d.timelock.CANCELLER_ROLE(), address(d.governor));

        // 5. El Timelock pasa a ser admin y upgrader de AgroTrace.
        d.agro.grantRole(d.agro.DEFAULT_ADMIN_ROLE(), address(d.timelock));
        d.agro.grantRole(d.agro.UPGRADER_ROLE(), address(d.timelock));

        // 6. El deployer renuncia a todo (primero UPGRADER, después admin).
        d.agro.renounceRole(d.agro.UPGRADER_ROLE(), deployer);
        d.agro.renounceRole(d.agro.DEFAULT_ADMIN_ROLE(), deployer);
        d.timelock.renounceRole(d.timelock.DEFAULT_ADMIN_ROLE(), deployer);
    }

    /// @dev Post-condiciones del traspaso. Mejor revertir el script que dejar una DAO a medio armar.
    function _checkHandover(Deployment memory d, address deployer) internal view {
        bytes32 adminRole = d.agro.DEFAULT_ADMIN_ROLE();
        if (!d.agro.hasRole(adminRole, address(d.timelock))) revert HandoverFailed("timelock sin admin");
        if (!d.agro.hasRole(d.agro.UPGRADER_ROLE(), address(d.timelock))) {
            revert HandoverFailed("timelock sin upgrader");
        }
        if (d.agro.hasRole(adminRole, deployer)) revert HandoverFailed("deployer sigue admin");
        if (d.agro.hasRole(d.agro.UPGRADER_ROLE(), deployer)) revert HandoverFailed("deployer sigue upgrader");
        if (d.timelock.hasRole(d.timelock.DEFAULT_ADMIN_ROLE(), deployer)) revert HandoverFailed("deployer admin TL");
        if (!d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), address(d.governor))) {
            revert HandoverFailed("governor sin proposer");
        }
    }

    function _log(Deployment memory d, Config memory cfg) internal pure {
        console2.log("AgroTrace (proxy):     ", address(d.agro));
        console2.log("AgroGovToken (AGT):    ", address(d.token));
        console2.log("TimelockController:    ", address(d.timelock));
        console2.log("AgroGovernor:          ", address(d.governor));
        console2.log("votingDelay (bloques): ", cfg.votingDelay);
        console2.log("votingPeriod (bloques):", cfg.votingPeriod);
        console2.log("quorum (%):            ", cfg.quorumPercent);
        console2.log("timelock minDelay (s): ", cfg.timelockMinDelay);
    }
}
