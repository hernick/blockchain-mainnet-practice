// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title AgroGovToken - Token de gobernanza de AgroTrace (AGT)
/// @author Hernán Figueroa (proyecto final - Máster en Blockchain + IA)
/// @notice ERC20 con poder de voto (ERC20Votes) y aprobaciones por firma (ERC20Permit / EIP-2612).
///         Lo usa AgroGovernor para contar votos y calcular el quórum.
/// @dev Decisiones de diseño:
///      - Suministro FIJO: todo se emite en el constructor y no hay función `mint`. Así nadie (ni la DAO)
///        puede inflar el poder de voto. Si más adelante hiciera falta, se agrega en un contrato nuevo.
///      - Reloj por número de bloque (default de ERC20Votes), coherente con los parámetros del Governor
///        expresados en bloques (votingDelay / votingPeriod).
///      - IMPORTANTE: los tokens NO votan solos. Cada holder tiene que llamar `delegate(self)` (o delegar en
///        otra dirección) para que su saldo cuente como votos.
contract AgroGovToken is ERC20, ERC20Permit, ERC20Votes {
    error ZeroRecipient();

    /// @param recipient Dirección que recibe todo el suministro inicial (ej.: deployer o tesorería/Safe).
    /// @param initialSupply Suministro total en unidades mínimas (18 decimales).
    constructor(address recipient, uint256 initialSupply)
        ERC20("AgroTrace Governance", "AGT")
        ERC20Permit("AgroTrace Governance")
    {
        if (recipient == address(0)) revert ZeroRecipient();
        _mint(recipient, initialSupply);
    }

    // -------------------------------------------------------------
    // Overrides requeridos por Solidity (herencia múltiple)
    // -------------------------------------------------------------

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
