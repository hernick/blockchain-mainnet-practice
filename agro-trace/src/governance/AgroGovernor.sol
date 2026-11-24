// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title AgroGovernor - Gobernanza on-chain de AgroTrace
/// @author Hernán Figueroa (proyecto final - Máster en Blockchain + IA)
/// @notice Flujo: propose -> (votingDelay) -> votación (votingPeriod) -> queue en el Timelock
///         -> (minDelay) -> execute. El Timelock es quien ejecuta, así que ÉL es el admin de AgroTrace.
/// @dev Composición estándar de OpenZeppelin 5 (mismo esquema que el Contracts Wizard):
///      - GovernorSettings: votingDelay, votingPeriod y proposalThreshold modificables por la propia DAO.
///      - GovernorCountingSimple: votos A favor / En contra / Abstención (abstención suma al quórum).
///      - GovernorVotes: lee el poder de voto de AgroGovToken (ERC20Votes) en el bloque del snapshot.
///      - GovernorVotesQuorumFraction: quórum = % del suministro total en el snapshot.
///      - GovernorTimelockControl: las propuestas aprobadas se encolan y ejecutan vía TimelockController.
///      No es upgradeable a propósito: la DAO puede migrar a un Governor nuevo dándole PROPOSER_ROLE en el
///      Timelock mediante una propuesta (el Timelock y AgroTrace conservan su dirección).
contract AgroGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /// @param token Token de votos (AgroGovToken).
    /// @param timelock TimelockController que ejecuta las propuestas.
    /// @param initialVotingDelay Bloques entre `propose` y el inicio de la votación (snapshot).
    /// @param initialVotingPeriod Duración de la votación en bloques (~12 s por bloque en Ethereum).
    /// @param initialProposalThreshold Votos mínimos para poder proponer (0 = cualquiera).
    /// @param quorumNumerator Quórum en % del suministro total (ej.: 4 = 4%).
    constructor(
        IVotes token,
        TimelockController timelock,
        uint48 initialVotingDelay,
        uint32 initialVotingPeriod,
        uint256 initialProposalThreshold,
        uint256 quorumNumerator
    )
        Governor("AgroGovernor")
        GovernorSettings(initialVotingDelay, initialVotingPeriod, initialProposalThreshold)
        GovernorVotes(token)
        GovernorVotesQuorumFraction(quorumNumerator)
        GovernorTimelockControl(timelock)
    {}

    // -------------------------------------------------------------
    // Overrides requeridos por Solidity (herencia múltiple)
    // -------------------------------------------------------------

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function quorum(uint256 blockNumber) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return super.quorum(blockNumber);
    }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
