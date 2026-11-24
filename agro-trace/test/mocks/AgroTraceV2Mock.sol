// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AgroTrace} from "../../src/AgroTrace.sol";

/// @title AgroTraceV2Mock - Implementación V2 de ejemplo para testear upgrades
/// @notice Agrega una función nueva usando su PROPIO namespace ERC-7201, sin tocar el storage de V1.
/// @dev Si V2 necesitara campos nuevos en `Lot`, solo se pueden AGREGAR al final del struct
///      (nunca reordenar ni borrar), porque el layout existente ya está en el storage del proxy.
/// @custom:oz-upgrades-from AgroTrace
contract AgroTraceV2Mock is AgroTrace {
    /// @custom:storage-location erc7201:agrotrace.storage.AgroTraceV2
    struct AgroTraceV2Storage {
        mapping(uint256 lotId => string note) notes;
    }

    // keccak256(abi.encode(uint256(keccak256("agrotrace.storage.AgroTraceV2")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant V2_STORAGE_LOCATION = 0xbaeb5541b95ccd1b31caccec923b82f58dcb6ff89e8630612d91c0dddc1da400;

    function version() external pure override returns (string memory) {
        return "2.0.0";
    }

    function setNote(uint256 lotId, string calldata note) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getV2Storage().notes[lotId] = note;
    }

    function noteOf(uint256 lotId) external view returns (string memory) {
        return _getV2Storage().notes[lotId];
    }

    function _getV2Storage() private pure returns (AgroTraceV2Storage storage $) {
        assembly {
            $.slot := V2_STORAGE_LOCATION
        }
    }
}
