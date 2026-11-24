// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/// @title AgroTrace - Trazabilidad de lotes agrícolas on-chain
/// @author Hernán Figueroa (proyecto final - Máster en Blockchain + IA)
/// @notice Registra lotes agrícolas y la cadena de custodia
///         productor -> acopiador -> procesador -> distribuidor -> minorista.
/// @dev Contrato upgradeable con patrón UUPS (OpenZeppelin v5) y storage namespaced ERC-7201.
///      Se despliega SIEMPRE detrás de un ERC1967Proxy; la implementación nunca se usa directo.
contract AgroTrace is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    // =============================================================
    //                            TIPOS
    // =============================================================

    /// @notice Etapas de la cadena de suministro, en el orden obligatorio.
    /// @dev Un uint8 alcanza y entra en el mismo slot que otros campos (packing).
    enum Stage {
        Producer, // 0 - productor
        Collector, // 1 - acopiador
        Processor, // 2 - procesador
        Distributor, // 3 - distribuidor
        Retailer // 4 - minorista (etapa final)
    }

    /// @notice Datos de un lote. Ordenados para ocupar 4 slots de storage (en vez de 9).
    /// @dev Slot 0: producer (20) + harvestDate (8) + certifications (2) + stage (1) = 31 bytes
    ///      Slot 1: custodian (20) + latitude (4) + longitude (4)                   = 28 bytes
    ///      Slot 2: cropType (32)
    ///      Slot 3: metadataHash (32)
    struct Lot {
        address producer; // productor que registró el lote
        uint64 harvestDate; // fecha de cosecha (unix timestamp, segundos)
        uint16 certifications; // bitmask de certificaciones (ver constantes CERT_*)
        Stage stage; // etapa actual
        address custodian; // custodio actual (quien puede transferir)
        int32 latitude; // latitud * 1e6  (ej: -34.603722 -> -34603722)
        int32 longitude; // longitud * 1e6 (ej: -58.381592 -> -58381592)
        bytes32 cropType; // tipo de cultivo, ej: bytes32("SOJA")
        bytes32 metadataHash; // hash de datos off-chain (IPFS, informe de IA, fotos...)
    }

    /// @notice Parámetros de entrada para registrar un lote (se lee desde calldata, sin copiar a memoria).
    struct LotInput {
        int32 latitude;
        int32 longitude;
        uint64 harvestDate;
        bytes32 cropType;
        uint16 certifications;
        bytes32 metadataHash;
    }

    /// @custom:storage-location erc7201:agrotrace.storage.AgroTrace
    struct AgroTraceStorage {
        uint256 lotCount; // último id asignado (los ids arrancan en 1; 0 = inexistente)
        mapping(uint256 lotId => Lot) lots;
    }

    // =============================================================
    //                          CONSTANTES
    // =============================================================

    /// @dev keccak256(abi.encode(uint256(keccak256("agrotrace.storage.AgroTrace")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AGRO_TRACE_STORAGE_LOCATION =
        0xf943234a58bc80289999890a503659168ee97dfa75b517e58ac7ec001b03aa00;

    // Roles (AccessControl). DEFAULT_ADMIN_ROLE administra todos.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PRODUCER_ROLE = keccak256("PRODUCER_ROLE");
    bytes32 public constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");
    bytes32 public constant PROCESSOR_ROLE = keccak256("PROCESSOR_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant RETAILER_ROLE = keccak256("RETAILER_ROLE");

    // Certificaciones (bitmask). Se pueden combinar: CERT_ORGANIC | CERT_NON_GMO.
    uint16 public constant CERT_ORGANIC = 1 << 0;
    uint16 public constant CERT_FAIR_TRADE = 1 << 1;
    uint16 public constant CERT_GLOBAL_GAP = 1 << 2;
    uint16 public constant CERT_RAINFOREST = 1 << 3;
    uint16 public constant CERT_NON_GMO = 1 << 4;
    /// @dev Máscara con todos los bits válidos; cualquier otro bit se rechaza.
    uint16 public constant CERT_MASK = 0x1F;

    // Rangos de coordenadas escaladas por 1e6.
    int32 private constant MAX_LAT = 90_000_000;
    int32 private constant MAX_LON = 180_000_000;

    // =============================================================
    //                            EVENTOS
    // =============================================================

    event LotRegistered(
        uint256 indexed lotId,
        address indexed producer,
        bytes32 indexed cropType,
        int32 latitude,
        int32 longitude,
        uint64 harvestDate,
        uint16 certifications
    );

    event LotUpdated(uint256 indexed lotId, uint16 certifications, bytes32 metadataHash);

    /// @notice Se emite en cada cambio de custodia. Es la "historia" del lote que leen los indexadores.
    event CustodyTransferred(
        uint256 indexed lotId, address indexed from, address indexed to, Stage fromStage, Stage toStage
    );

    // =============================================================
    //                            ERRORES
    // =============================================================
    // Custom errors: más baratos que revert strings (selector de 4 bytes) y con contexto.

    error ZeroAddress();
    error LotNotFound(uint256 lotId);
    error InvalidCoordinates(int32 latitude, int32 longitude);
    error InvalidHarvestDate(uint64 harvestDate);
    error InvalidCropType();
    error InvalidCertifications(uint16 certifications);
    error NotLotProducer(uint256 lotId, address caller);
    error NotCustodian(uint256 lotId, address caller);
    error LotAlreadyTransferred(uint256 lotId);
    error InvalidStageTransition(Stage current, Stage requested);
    error RecipientMissingRole(address recipient, bytes32 role);

    // =============================================================
    //                        INICIALIZACIÓN
    // =============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Bloquea la inicialización de la implementación: solo el proxy se inicializa.
        _disableInitializers();
    }

    /// @notice Inicializa el proxy (reemplaza al constructor). Solo se puede llamar una vez.
    /// @param admin Dirección que recibe DEFAULT_ADMIN_ROLE y UPGRADER_ROLE (idealmente una multisig).
    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    // =============================================================
    //                     FUNCIONES DE ESCRITURA
    // =============================================================

    /// @notice Registra un lote nuevo. El productor queda como primer custodio.
    /// @param input Datos del lote (calldata: no se copia a memoria).
    /// @return lotId Id del lote (empieza en 1).
    function registerLot(LotInput calldata input) external onlyRole(PRODUCER_ROLE) returns (uint256 lotId) {
        _validateCoordinates(input.latitude, input.longitude);
        // La manipulación de timestamp por validadores (segundos) es irrelevante para una fecha de cosecha.
        // forge-lint: disable-next-line(block-timestamp)
        if (input.harvestDate == 0 || input.harvestDate > block.timestamp) {
            revert InvalidHarvestDate(input.harvestDate);
        }
        if (input.cropType == bytes32(0)) revert InvalidCropType();
        _validateCertifications(input.certifications);

        AgroTraceStorage storage $ = _getStorage();
        // Un uint256 no va a desbordar en la práctica; unchecked ahorra el chequeo.
        unchecked {
            lotId = ++$.lotCount;
        }

        // Escritura campo por campo sobre el puntero storage: el compilador agrupa por slot.
        Lot storage lot = $.lots[lotId];
        lot.producer = msg.sender;
        lot.harvestDate = input.harvestDate;
        lot.certifications = input.certifications;
        // lot.stage = Stage.Producer (valor por defecto = 0, no hace falta escribirlo)
        lot.custodian = msg.sender;
        lot.latitude = input.latitude;
        lot.longitude = input.longitude;
        lot.cropType = input.cropType;
        if (input.metadataHash != bytes32(0)) lot.metadataHash = input.metadataHash;

        emit LotRegistered(
            lotId, msg.sender, input.cropType, input.latitude, input.longitude, input.harvestDate, input.certifications
        );
    }

    /// @notice Actualiza certificaciones y hash de metadatos de un lote.
    /// @dev Solo el productor que lo registró (y que siga teniendo PRODUCER_ROLE), y solo mientras
    ///      el lote no salió de su custodia: después de la primera transferencia los datos quedan congelados.
    function updateLot(uint256 lotId, uint16 certifications, bytes32 metadataHash) external onlyRole(PRODUCER_ROLE) {
        Lot storage lot = _getExistingLot(lotId);
        if (lot.producer != msg.sender) revert NotLotProducer(lotId, msg.sender);
        if (lot.stage != Stage.Producer) revert LotAlreadyTransferred(lotId);
        _validateCertifications(certifications);

        lot.certifications = certifications;
        lot.metadataHash = metadataHash;

        emit LotUpdated(lotId, certifications, metadataHash);
    }

    /// @notice Transfiere la custodia del lote a la siguiente etapa.
    /// @param lotId Id del lote.
    /// @param to Nuevo custodio; debe tener el rol de la etapa `nextStage`.
    /// @param nextStage Etapa destino; tiene que ser exactamente la siguiente a la actual.
    function transferCustody(uint256 lotId, address to, Stage nextStage) external {
        if (to == address(0)) revert ZeroAddress();
        Lot storage lot = _getExistingLot(lotId);

        // Una sola lectura del slot 1 para custodian y del slot 0 para stage.
        address from = lot.custodian;
        if (from != msg.sender) revert NotCustodian(lotId, msg.sender);

        Stage current = lot.stage;
        // Orden estricto: no se puede saltar etapas, retroceder ni pasar de Retailer.
        if (current == Stage.Retailer || uint8(nextStage) != uint8(current) + 1) {
            revert InvalidStageTransition(current, nextStage);
        }

        bytes32 role = roleForStage(nextStage);
        if (!hasRole(role, to)) revert RecipientMissingRole(to, role);

        lot.stage = nextStage;
        lot.custodian = to;

        emit CustodyTransferred(lotId, from, to, current, nextStage);
    }

    // =============================================================
    //                       FUNCIONES DE LECTURA
    // =============================================================

    /// @notice Devuelve todos los datos de un lote. Revierte si no existe.
    function getLot(uint256 lotId) external view returns (Lot memory) {
        return _getExistingLot(lotId);
    }

    /// @notice Cantidad de lotes registrados (= último id asignado).
    function lotCount() external view returns (uint256) {
        return _getStorage().lotCount;
    }

    /// @notice Indica si el lote tiene una certificación (o combinación) dada.
    function hasCertification(uint256 lotId, uint16 cert) external view returns (bool) {
        return _getExistingLot(lotId).certifications & cert == cert;
    }

    /// @notice Rol requerido para recibir un lote en cada etapa.
    function roleForStage(Stage stage) public pure returns (bytes32) {
        if (stage == Stage.Producer) return PRODUCER_ROLE;
        if (stage == Stage.Collector) return COLLECTOR_ROLE;
        if (stage == Stage.Processor) return PROCESSOR_ROLE;
        if (stage == Stage.Distributor) return DISTRIBUTOR_ROLE;
        return RETAILER_ROLE;
    }

    /// @notice Versión de la implementación (útil para verificar upgrades).
    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }

    // =============================================================
    //                           INTERNAS
    // =============================================================

    /// @dev Solo UPGRADER_ROLE puede cambiar la implementación del proxy.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function _getStorage() private pure returns (AgroTraceStorage storage $) {
        assembly {
            $.slot := AGRO_TRACE_STORAGE_LOCATION
        }
    }

    function _getExistingLot(uint256 lotId) private view returns (Lot storage lot) {
        lot = _getStorage().lots[lotId];
        // Todo lote registrado tiene producer != 0, así que sirve como marca de existencia.
        if (lot.producer == address(0)) revert LotNotFound(lotId);
    }

    function _validateCoordinates(int32 latitude, int32 longitude) private pure {
        if (latitude > MAX_LAT || latitude < -MAX_LAT || longitude > MAX_LON || longitude < -MAX_LON) {
            revert InvalidCoordinates(latitude, longitude);
        }
    }

    function _validateCertifications(uint16 certifications) private pure {
        if (certifications & ~CERT_MASK != 0) revert InvalidCertifications(certifications);
    }
}
