// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {AgroTrace} from "../src/AgroTrace.sol";
import {AgroTraceV2Mock} from "./mocks/AgroTraceV2Mock.sol";

/// @dev Contrato con código pero sin proxiableUUID(): no es una implementación UUPS válida.
contract NotUUPS {}

/// @notice Tests de AgroTrace: camino feliz, control de acceso, edge cases y upgrades UUPS.
contract AgroTraceTest is Test {
    AgroTrace internal implementation;
    AgroTrace internal agro; // apunta al PROXY con la ABI de AgroTrace

    address internal admin = makeAddr("admin");
    address internal producer = makeAddr("producer");
    address internal producer2 = makeAddr("producer2");
    address internal collector = makeAddr("collector");
    address internal processor = makeAddr("processor");
    address internal distributor = makeAddr("distributor");
    address internal retailer = makeAddr("retailer");
    address internal stranger = makeAddr("stranger");

    // Datos de ejemplo: lote de soja en Pergamino, Buenos Aires.
    int32 internal constant LAT = -33_889_444; // -33.889444
    int32 internal constant LON = -60_573_611; // -60.573611
    bytes32 internal constant SOJA = "SOJA";
    bytes32 internal constant META = keccak256("ipfs://bafy...informe-ia");
    uint64 internal constant HARVEST = 1_740_000_000; // feb-2025

    function setUp() public {
        vm.warp(1_760_000_000); // "hoy" en el test (oct-2025)

        implementation = new AgroTrace();
        bytes memory initData = abi.encodeCall(AgroTrace.initialize, (admin));
        agro = AgroTrace(address(new ERC1967Proxy(address(implementation), initData)));

        vm.startPrank(admin);
        agro.grantRole(agro.PRODUCER_ROLE(), producer);
        agro.grantRole(agro.PRODUCER_ROLE(), producer2);
        agro.grantRole(agro.COLLECTOR_ROLE(), collector);
        agro.grantRole(agro.PROCESSOR_ROLE(), processor);
        agro.grantRole(agro.DISTRIBUTOR_ROLE(), distributor);
        agro.grantRole(agro.RETAILER_ROLE(), retailer);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _input() internal pure returns (AgroTrace.LotInput memory) {
        return AgroTrace.LotInput({
            latitude: LAT,
            longitude: LON,
            harvestDate: HARVEST,
            cropType: SOJA,
            certifications: 1 | 16, // CERT_ORGANIC | CERT_NON_GMO
            metadataHash: META
        });
    }

    function _register() internal returns (uint256 lotId) {
        vm.prank(producer);
        lotId = agro.registerLot(_input());
    }

    function _moveTo(uint256 lotId, AgroTrace.Stage target) internal {
        address[5] memory actors = [producer, collector, processor, distributor, retailer];
        AgroTrace.Lot memory lot = agro.getLot(lotId);
        for (uint8 s = uint8(lot.stage); s < uint8(target); s++) {
            vm.prank(actors[s]);
            agro.transferCustody(lotId, actors[s + 1], AgroTrace.Stage(s + 1));
        }
    }

    // ---------------------------------------------------------------
    // Inicialización
    // ---------------------------------------------------------------

    function test_Initialize_SetsAdminRoles() public view {
        assertTrue(agro.hasRole(agro.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(agro.hasRole(agro.UPGRADER_ROLE(), admin));
        assertEq(agro.version(), "1.0.0");
        assertEq(agro.lotCount(), 0);
        // El proxy apunta a la implementación correcta (slot ERC-1967).
        address impl = address(uint160(uint256(vm.load(address(agro), ERC1967Utils.IMPLEMENTATION_SLOT))));
        assertEq(impl, address(implementation));
    }

    function test_RevertWhen_InitializeTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        agro.initialize(stranger);
    }

    function test_RevertWhen_InitializeImplementationDirectly() public {
        // _disableInitializers() en el constructor impide tomar control de la implementación.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(stranger);
    }

    function test_RevertWhen_InitializeWithZeroAdmin() public {
        AgroTrace impl = new AgroTrace();
        vm.expectRevert(AgroTrace.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(AgroTrace.initialize, (address(0))));
    }

    // ---------------------------------------------------------------
    // Registro de lotes
    // ---------------------------------------------------------------

    function test_RegisterLot_StoresDataAndEmits() public {
        vm.expectEmit(true, true, true, true, address(agro));
        emit AgroTrace.LotRegistered(1, producer, SOJA, LAT, LON, HARVEST, 17);

        uint256 lotId = _register();
        assertEq(lotId, 1);
        assertEq(agro.lotCount(), 1);

        AgroTrace.Lot memory lot = agro.getLot(lotId);
        assertEq(lot.producer, producer);
        assertEq(lot.custodian, producer);
        assertEq(lot.latitude, LAT);
        assertEq(lot.longitude, LON);
        assertEq(lot.harvestDate, HARVEST);
        assertEq(lot.cropType, SOJA);
        assertEq(lot.certifications, 17);
        assertEq(lot.metadataHash, META);
        assertEq(uint8(lot.stage), uint8(AgroTrace.Stage.Producer));

        assertTrue(agro.hasCertification(lotId, agro.CERT_ORGANIC()));
        assertTrue(agro.hasCertification(lotId, agro.CERT_ORGANIC() | agro.CERT_NON_GMO()));
        assertFalse(agro.hasCertification(lotId, agro.CERT_FAIR_TRADE()));
    }

    function test_RegisterLot_IncrementsIds() public {
        assertEq(_register(), 1);
        assertEq(_register(), 2);
        vm.prank(producer2);
        assertEq(agro.registerLot(_input()), 3);
        assertEq(agro.lotCount(), 3);
    }

    function test_RegisterLot_UsesFourStorageSlots() public {
        uint256 lotId = _register();
        // Slot del mapping `lots` dentro del namespace ERC-7201 (base + 1).
        bytes32 base = 0xf943234a58bc80289999890a503659168ee97dfa75b517e58ac7ec001b03aa00;
        bytes32 lotSlot = keccak256(abi.encode(lotId, uint256(base) + 1));
        for (uint256 i; i < 4; i++) {
            assertTrue(vm.load(address(agro), bytes32(uint256(lotSlot) + i)) != bytes32(0), "slot vacio");
        }
        assertEq(vm.load(address(agro), bytes32(uint256(lotSlot) + 4)), bytes32(0), "usa mas de 4 slots");
    }

    function test_RevertWhen_RegisterWithoutRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agro.PRODUCER_ROLE()
            )
        );
        vm.prank(stranger);
        agro.registerLot(_input());
    }

    function test_RevertWhen_LatitudeOutOfRange() public {
        AgroTrace.LotInput memory input = _input();
        input.latitude = 90_000_001;
        vm.expectRevert(abi.encodeWithSelector(AgroTrace.InvalidCoordinates.selector, input.latitude, LON));
        vm.prank(producer);
        agro.registerLot(input);
    }

    function test_RevertWhen_LongitudeOutOfRange() public {
        AgroTrace.LotInput memory input = _input();
        input.longitude = -180_000_001;
        vm.expectRevert(abi.encodeWithSelector(AgroTrace.InvalidCoordinates.selector, LAT, input.longitude));
        vm.prank(producer);
        agro.registerLot(input);
    }

    function test_RegisterLot_AcceptsCoordinateBounds() public {
        AgroTrace.LotInput memory input = _input();
        input.latitude = -90_000_000;
        input.longitude = 180_000_000;
        vm.prank(producer);
        agro.registerLot(input);
    }

    function test_RevertWhen_HarvestDateInFuture() public {
        AgroTrace.LotInput memory input = _input();
        input.harvestDate = uint64(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(AgroTrace.InvalidHarvestDate.selector, input.harvestDate));
        vm.prank(producer);
        agro.registerLot(input);
    }

    function test_RevertWhen_HarvestDateZero() public {
        AgroTrace.LotInput memory input = _input();
        input.harvestDate = 0;
        vm.expectRevert(abi.encodeWithSelector(AgroTrace.InvalidHarvestDate.selector, 0));
        vm.prank(producer);
        agro.registerLot(input);
    }

    function test_RevertWhen_CropTypeEmpty() public {
        AgroTrace.LotInput memory input = _input();
        input.cropType = bytes32(0);
        vm.expectRevert(AgroTrace.InvalidCropType.selector);
        vm.prank(producer);
        agro.registerLot(input);
    }

    function test_RevertWhen_UnknownCertificationBit() public {
        AgroTrace.LotInput memory input = _input();
        input.certifications = 1 << 5;
        vm.expectRevert(abi.encodeWithSelector(AgroTrace.InvalidCertifications.selector, input.certifications));
        vm.prank(producer);
        agro.registerLot(input);
    }

    function testFuzz_RegisterLot_ValidCoordinates(int32 lat, int32 lon) public {
        lat = int32(bound(lat, -90_000_000, 90_000_000));
        lon = int32(bound(lon, -180_000_000, 180_000_000));
        AgroTrace.LotInput memory input = _input();
        input.latitude = lat;
        input.longitude = lon;
        vm.prank(producer);
        uint256 lotId = agro.registerLot(input);
        AgroTrace.Lot memory lot = agro.getLot(lotId);
        assertEq(lot.latitude, lat);
        assertEq(lot.longitude, lon);
    }

    // ---------------------------------------------------------------
    // Actualización de lotes
    // ---------------------------------------------------------------

    function test_UpdateLot_ByProducer() public {
        uint256 lotId = _register();
        bytes32 newMeta = keccak256("nuevo-informe");

        vm.expectEmit(true, false, false, true, address(agro));
        emit AgroTrace.LotUpdated(lotId, 1 | 2, newMeta);
        vm.prank(producer);
        agro.updateLot(lotId, 1 | 2, newMeta);

        AgroTrace.Lot memory lot = agro.getLot(lotId);
        assertEq(lot.certifications, 3);
        assertEq(lot.metadataHash, newMeta);
    }

    function test_RevertWhen_UpdateByOtherProducer() public {
        uint256 lotId = _register();
        vm.expectRevert(abi.encodeWithSelector(AgroTrace.NotLotProducer.selector, lotId, producer2));
        vm.prank(producer2);
        agro.updateLot(lotId, 1, META);
    }

    function test_RevertWhen_UpdateWithoutRole() public {
        uint256 lotId = _register();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agro.PRODUCER_ROLE()
            )
        );
        vm.prank(stranger);
        agro.updateLot(lotId, 1, META);
    }

    function test_RevertWhen_UpdateAfterProducerRoleRevoked() public {
        uint256 lotId = _register();
        bytes32 producerRole = agro.PRODUCER_ROLE();
        vm.prank(admin);
        agro.revokeRole(producerRole, producer);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, producer, producerRole)
        );
        vm.prank(producer);
        agro.updateLot(lotId, 1, META);
    }

    function test_RevertWhen_UpdateAfterTransfer() public {
        uint256 lotId = _register();
        _moveTo(lotId, AgroTrace.Stage.Collector);
        vm.expectRevert(abi.encodeWithSelector(AgroTrace.LotAlreadyTransferred.selector, lotId));
        vm.prank(producer);
        agro.updateLot(lotId, 1, META);
    }

    function test_RevertWhen_UpdateNonexistentLot() public {
        vm.expectRevert(abi.encodeWithSelector(AgroTrace.LotNotFound.selector, 42));
        vm.prank(producer);
        agro.updateLot(42, 1, META);
    }

    // ---------------------------------------------------------------
    // Cadena de custodia
    // ---------------------------------------------------------------

    function test_FullSupplyChain_EmitsEachHandoff() public {
        uint256 lotId = _register();
        address[5] memory actors = [producer, collector, processor, distributor, retailer];

        for (uint8 s; s < 4; s++) {
            vm.expectEmit(true, true, true, true, address(agro));
            emit AgroTrace.CustodyTransferred(
                lotId, actors[s], actors[s + 1], AgroTrace.Stage(s), AgroTrace.Stage(s + 1)
            );
            vm.prank(actors[s]);
            agro.transferCustody(lotId, actors[s + 1], AgroTrace.Stage(s + 1));

            AgroTrace.Lot memory lot = agro.getLot(lotId);
            assertEq(lot.custodian, actors[s + 1]);
            assertEq(uint8(lot.stage), s + 1);
            assertEq(lot.producer, producer); // el productor original no cambia
        }
    }

    function test_RevertWhen_TransferByNonCustodian() public {
        uint256 lotId = _register();
        vm.expectRevert(abi.encodeWithSelector(AgroTrace.NotCustodian.selector, lotId, stranger));
        vm.prank(stranger);
        agro.transferCustody(lotId, collector, AgroTrace.Stage.Collector);
    }

    function test_RevertWhen_PreviousCustodianTriesAgain() public {
        uint256 lotId = _register();
        _moveTo(lotId, AgroTrace.Stage.Collector);
        vm.expectRevert(abi.encodeWithSelector(AgroTrace.NotCustodian.selector, lotId, producer));
        vm.prank(producer);
        agro.transferCustody(lotId, processor, AgroTrace.Stage.Processor);
    }

    function test_RevertWhen_SkippingStage() public {
        uint256 lotId = _register();
        vm.expectRevert(
            abi.encodeWithSelector(
                AgroTrace.InvalidStageTransition.selector, AgroTrace.Stage.Producer, AgroTrace.Stage.Processor
            )
        );
        vm.prank(producer);
        agro.transferCustody(lotId, processor, AgroTrace.Stage.Processor);
    }

    function test_RevertWhen_GoingBackwards() public {
        uint256 lotId = _register();
        _moveTo(lotId, AgroTrace.Stage.Processor);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgroTrace.InvalidStageTransition.selector, AgroTrace.Stage.Processor, AgroTrace.Stage.Collector
            )
        );
        vm.prank(processor);
        agro.transferCustody(lotId, collector, AgroTrace.Stage.Collector);
    }

    function test_RevertWhen_SameStage() public {
        uint256 lotId = _register();
        vm.expectRevert(
            abi.encodeWithSelector(
                AgroTrace.InvalidStageTransition.selector, AgroTrace.Stage.Producer, AgroTrace.Stage.Producer
            )
        );
        vm.prank(producer);
        agro.transferCustody(lotId, producer2, AgroTrace.Stage.Producer);
    }

    function test_RevertWhen_TransferAfterFinalStage() public {
        uint256 lotId = _register();
        _moveTo(lotId, AgroTrace.Stage.Retailer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgroTrace.InvalidStageTransition.selector, AgroTrace.Stage.Retailer, AgroTrace.Stage.Retailer
            )
        );
        vm.prank(retailer);
        agro.transferCustody(lotId, retailer, AgroTrace.Stage.Retailer);
    }

    function test_RevertWhen_InvalidEnumValue() public {
        uint256 lotId = _register();
        // Stage(5) no existe: el ABI decoder de Solidity revierte antes de entrar a la función.
        // Usamos una llamada de bajo nivel porque la ABI tipada no permite construir ese valor.
        vm.prank(producer);
        (bool ok,) =
            address(agro).call(abi.encodeWithSelector(AgroTrace.transferCustody.selector, lotId, collector, uint8(5)));
        assertFalse(ok);
        assertEq(uint8(agro.getLot(lotId).stage), uint8(AgroTrace.Stage.Producer));
    }

    function test_RevertWhen_RecipientMissingRole() public {
        uint256 lotId = _register();
        vm.expectRevert(
            abi.encodeWithSelector(AgroTrace.RecipientMissingRole.selector, stranger, agro.COLLECTOR_ROLE())
        );
        vm.prank(producer);
        agro.transferCustody(lotId, stranger, AgroTrace.Stage.Collector);
    }

    function test_RevertWhen_RecipientHasWrongStageRole() public {
        uint256 lotId = _register();
        // El distribuidor no puede recibir directo del productor aunque tenga un rol válido.
        vm.expectRevert(
            abi.encodeWithSelector(AgroTrace.RecipientMissingRole.selector, distributor, agro.COLLECTOR_ROLE())
        );
        vm.prank(producer);
        agro.transferCustody(lotId, distributor, AgroTrace.Stage.Collector);
    }

    function test_RevertWhen_TransferToZeroAddress() public {
        uint256 lotId = _register();
        vm.expectRevert(AgroTrace.ZeroAddress.selector);
        vm.prank(producer);
        agro.transferCustody(lotId, address(0), AgroTrace.Stage.Collector);
    }

    function test_RevertWhen_TransferNonexistentLot() public {
        vm.expectRevert(abi.encodeWithSelector(AgroTrace.LotNotFound.selector, 7));
        vm.prank(producer);
        agro.transferCustody(7, collector, AgroTrace.Stage.Collector);
    }

    function test_RevertWhen_GetNonexistentLot() public {
        vm.expectRevert(abi.encodeWithSelector(AgroTrace.LotNotFound.selector, 0));
        agro.getLot(0);
    }

    // ---------------------------------------------------------------
    // Upgrades UUPS
    // ---------------------------------------------------------------

    function test_RevertWhen_UpgradeByNonUpgrader() public {
        AgroTraceV2Mock v2 = new AgroTraceV2Mock();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agro.UPGRADER_ROLE()
            )
        );
        vm.prank(stranger);
        agro.upgradeToAndCall(address(v2), "");
    }

    function test_RevertWhen_UpgradeByProducer() public {
        AgroTraceV2Mock v2 = new AgroTraceV2Mock();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, producer, agro.UPGRADER_ROLE()
            )
        );
        vm.prank(producer);
        agro.upgradeToAndCall(address(v2), "");
    }

    function test_Upgrade_PreservesState() public {
        // Estado previo: dos lotes, uno a mitad de camino.
        uint256 lot1 = _register();
        uint256 lot2 = _register();
        _moveTo(lot1, AgroTrace.Stage.Processor);
        AgroTrace.Lot memory before1 = agro.getLot(lot1);

        AgroTraceV2Mock v2 = new AgroTraceV2Mock();
        vm.prank(admin);
        agro.upgradeToAndCall(address(v2), "");

        AgroTraceV2Mock agroV2 = AgroTraceV2Mock(address(agro));
        assertEq(agroV2.version(), "2.0.0");
        address impl = address(uint160(uint256(vm.load(address(agro), ERC1967Utils.IMPLEMENTATION_SLOT))));
        assertEq(impl, address(v2));

        // Estado y roles intactos.
        assertEq(agroV2.lotCount(), 2);
        AgroTrace.Lot memory after1 = agroV2.getLot(lot1);
        assertEq(keccak256(abi.encode(after1)), keccak256(abi.encode(before1)));
        assertEq(agroV2.getLot(lot2).custodian, producer);
        assertTrue(agroV2.hasRole(agroV2.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(agroV2.hasRole(agroV2.PROCESSOR_ROLE(), processor));

        // La lógica vieja sigue funcionando y la nueva también.
        vm.prank(processor);
        agroV2.transferCustody(lot1, distributor, AgroTrace.Stage.Distributor);
        vm.prank(admin);
        agroV2.setNote(lot1, "control de calidad OK");
        assertEq(agroV2.noteOf(lot1), "control de calidad OK");
        assertEq(agroV2.getLot(lot1).custodian, distributor);

        // Sigue sin poder re-inicializarse después del upgrade.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        agroV2.initialize(stranger);
    }

    function test_RevertWhen_UpgradeToNonUUPS() public {
        // Una implementación sin proxiableUUID() se rechaza (protege contra "brickear" el proxy).
        address notUups = address(new NotUUPS());
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, notUups));
        vm.prank(admin);
        agro.upgradeToAndCall(notUups, "");
    }
}
