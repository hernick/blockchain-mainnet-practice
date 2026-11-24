// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {AgroTrace} from "../src/AgroTrace.sol";
import {AgroGovToken} from "../src/governance/AgroGovToken.sol";
import {AgroGovernor} from "../src/governance/AgroGovernor.sol";
import {DeployGovernance} from "../script/DeployGovernance.s.sol";
import {AgroTraceV2Mock} from "./mocks/AgroTraceV2Mock.sol";

/// @notice Tests de gobernanza: traspaso de roles al Timelock y ciclo completo
///         propose -> vote -> queue -> execute (upgrade UUPS + permisos operativos).
contract AgroGovernanceTest is Test {
    // Parámetros "tipo Sepolia" (los mismos defaults que DeployGovernance).
    uint48 internal constant VOTING_DELAY = 1; // bloques
    uint32 internal constant VOTING_PERIOD = 50_400; // bloques (~7 días)
    uint256 internal constant QUORUM_PERCENT = 4; // % del suministro
    uint256 internal constant MIN_DELAY = 1 days; // segundos
    uint256 internal constant SUPPLY = 1_000_000 ether;

    uint8 internal constant AGAINST = 0;
    uint8 internal constant FOR = 1;

    AgroTrace internal agro;
    AgroGovToken internal token;
    TimelockController internal timelock;
    AgroGovernor internal governor;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice"); // 60% de los votos
    address internal bob = makeAddr("bob"); // 30%
    address internal carol = makeAddr("carol"); // 1% (< quórum)
    address internal producer = makeAddr("producer");
    address internal newProducer = makeAddr("newProducer");

    uint256 internal lotId;

    function setUp() public {
        vm.warp(1_760_000_000);
        vm.roll(100);

        // --- Mismo procedimiento que script/DeployGovernance.s.sol ---
        vm.startPrank(deployer);
        address impl = address(new AgroTrace());
        agro = AgroTrace(address(new ERC1967Proxy(impl, abi.encodeCall(AgroTrace.initialize, (deployer)))));

        // Roles operativos iniciales (antes del traspaso) + un lote para verificar que el estado sobrevive.
        agro.grantRole(agro.PRODUCER_ROLE(), producer);

        token = new AgroGovToken(deployer, SUPPLY);
        address[] memory none = new address[](0);
        address[] memory anyone = new address[](1);
        timelock = new TimelockController(MIN_DELAY, none, anyone, deployer);
        governor = new AgroGovernor(token, timelock, VOTING_DELAY, VOTING_PERIOD, 0, QUORUM_PERCENT);

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        agro.grantRole(agro.DEFAULT_ADMIN_ROLE(), address(timelock));
        agro.grantRole(agro.UPGRADER_ROLE(), address(timelock));
        agro.renounceRole(agro.UPGRADER_ROLE(), deployer);
        agro.renounceRole(agro.DEFAULT_ADMIN_ROLE(), deployer);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        // Reparto de tokens.
        token.transfer(alice, 600_000 ether);
        token.transfer(bob, 300_000 ether);
        token.transfer(carol, 10_000 ether);
        vm.stopPrank();

        // Cada holder delega en sí mismo para activar su poder de voto.
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(bob);
        token.delegate(bob);
        vm.prank(carol);
        token.delegate(carol);

        vm.prank(producer);
        lotId = agro.registerLot(
            AgroTrace.LotInput({
                latitude: -33_889_444,
                longitude: -60_573_611,
                harvestDate: 1_740_000_000,
                cropType: "SOJA",
                certifications: 1,
                metadataHash: keccak256("ipfs://lote-1")
            })
        );

        vm.roll(vm.getBlockNumber() + 1); // los checkpoints de votos quedan en el pasado
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _single(address target, bytes memory data)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = target;
        calldatas[0] = data;
    }

    function _propose(address[] memory t, uint256[] memory v, bytes[] memory c, string memory desc)
        internal
        returns (uint256 id)
    {
        vm.prank(alice);
        id = governor.propose(t, v, c, desc);
    }

    function _vote(uint256 id, address voter, uint8 support) internal {
        vm.prank(voter);
        governor.castVote(id, support);
    }

    function _toVoting() internal {
        vm.roll(vm.getBlockNumber() + VOTING_DELAY + 1);
    }

    function _toVotingEnd() internal {
        vm.roll(vm.getBlockNumber() + VOTING_PERIOD + 1);
    }

    /// @dev Pasa una propuesta de punta a punta (alice vota a favor) y la ejecuta.
    function _passAndExecute(address[] memory t, uint256[] memory v, bytes[] memory c, string memory desc)
        internal
        returns (uint256 id)
    {
        id = _propose(t, v, c, desc);
        _toVoting();
        _vote(id, alice, FOR);
        _toVotingEnd();
        bytes32 descHash = keccak256(bytes(desc));
        governor.queue(t, v, c, descHash);
        vm.warp(vm.getBlockTimestamp() + MIN_DELAY + 1);
        governor.execute(t, v, c, descHash);
    }

    // ---------------------------------------------------------------
    // Parámetros y traspaso de roles
    // ---------------------------------------------------------------

    function test_Governor_Parameters() public view {
        assertEq(governor.name(), "AgroGovernor");
        assertEq(governor.votingDelay(), VOTING_DELAY);
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), 0);
        assertEq(governor.quorumNumerator(), QUORUM_PERCENT);
        assertEq(governor.quorum(block.number - 1), SUPPLY * QUORUM_PERCENT / 100); // 40.000 AGT
        assertEq(governor.timelock(), address(timelock));
        assertEq(address(governor.token()), address(token));
        assertEq(timelock.getMinDelay(), MIN_DELAY);
        assertEq(token.symbol(), "AGT");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_Handover_TimelockHoldsAdminAndUpgrader() public view {
        assertTrue(agro.hasRole(agro.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(agro.hasRole(agro.UPGRADER_ROLE(), address(timelock)));
        assertFalse(agro.hasRole(agro.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(agro.hasRole(agro.UPGRADER_ROLE(), deployer));
        // El Governor NO es admin de AgroTrace: solo puede proponer en el Timelock.
        assertFalse(agro.hasRole(agro.DEFAULT_ADMIN_ROLE(), address(governor)));

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0))); // ejecución abierta
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock))); // auto-administrado
    }

    function test_RevertWhen_FormerAdminUpgradesAfterHandover() public {
        address v2 = address(new AgroTraceV2Mock());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, agro.UPGRADER_ROLE()
            )
        );
        vm.prank(deployer);
        agro.upgradeToAndCall(v2, "");
    }

    function test_RevertWhen_FormerAdminGrantsRoleAfterHandover() public {
        bytes32 role = agro.PRODUCER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, agro.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(deployer);
        agro.grantRole(role, newProducer);
    }

    function test_RevertWhen_TokenWhaleUpgradesDirectly() public {
        // Tener el 60% de los votos no da permisos directos: todo pasa por propuesta + Timelock.
        address v2 = address(new AgroTraceV2Mock());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, agro.UPGRADER_ROLE()
            )
        );
        vm.prank(alice);
        agro.upgradeToAndCall(v2, "");
    }

    function test_RevertWhen_EOASchedulesOnTimelockDirectly() public {
        bytes memory data = abi.encodeCall(agro.upgradeToAndCall, (address(1), ""));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, timelock.PROPOSER_ROLE()
            )
        );
        vm.prank(alice);
        timelock.schedule(address(agro), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
    }

    function test_Token_VotesRequireDelegation() public {
        address dave = makeAddr("dave");
        vm.prank(alice);
        token.transfer(dave, 1000 ether);
        assertEq(token.getVotes(dave), 0); // tiene saldo pero no votos
        vm.prank(dave);
        token.delegate(dave);
        assertEq(token.getVotes(dave), 1000 ether);
    }

    // ---------------------------------------------------------------
    // Ciclo de vida completo
    // ---------------------------------------------------------------

    function test_Governance_FullUpgradeLifecycle_PreservesState() public {
        AgroTrace.Lot memory before = agro.getLot(lotId);
        address v2 = address(new AgroTraceV2Mock());

        // Propuesta con 2 acciones atómicas: upgrade + usar la función nueva de V2 (solo admin = Timelock).
        address[] memory t = new address[](2);
        uint256[] memory v = new uint256[](2);
        bytes[] memory c = new bytes[](2);
        t[0] = address(agro);
        c[0] = abi.encodeCall(agro.upgradeToAndCall, (v2, ""));
        t[1] = address(agro);
        c[1] = abi.encodeCall(AgroTraceV2Mock.setNote, (lotId, "aprobado por la DAO"));
        string memory desc = "AGP-1: upgrade a AgroTrace v2";
        bytes32 descHash = keccak256(bytes(desc));

        uint256 id = _propose(t, v, c, desc);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));

        _toVoting();
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active));
        _vote(id, alice, FOR);
        _vote(id, bob, AGAINST);
        (uint256 against, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, 600_000 ether);
        assertEq(against, 300_000 ether);

        _toVotingEnd();
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));

        governor.queue(t, v, c, descHash);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Queued));
        assertEq(governor.proposalEta(id), block.timestamp + MIN_DELAY);

        vm.warp(vm.getBlockTimestamp() + MIN_DELAY);
        vm.prank(makeAddr("anyone")); // ejecución abierta: cualquiera puede ejecutar
        governor.execute(t, v, c, descHash);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Executed));

        // Upgrade aplicado y estado intacto.
        AgroTraceV2Mock agroV2 = AgroTraceV2Mock(address(agro));
        assertEq(agroV2.version(), "2.0.0");
        assertEq(agroV2.noteOf(lotId), "aprobado por la DAO");
        assertEq(agro.lotCount(), 1);
        assertEq(keccak256(abi.encode(agro.getLot(lotId))), keccak256(abi.encode(before)));
        assertTrue(agro.hasRole(agro.PRODUCER_ROLE(), producer));
        assertTrue(agro.hasRole(agro.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(agro.hasRole(agro.UPGRADER_ROLE(), address(timelock)));
    }

    function test_Governance_GrantsOperationalRole() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(agro), abi.encodeCall(agro.grantRole, (agro.PRODUCER_ROLE(), newProducer)));
        _passAndExecute(t, v, c, "AGP-2: alta de productor");

        assertTrue(agro.hasRole(agro.PRODUCER_ROLE(), newProducer));
    }

    function test_Governance_RevokesOperationalRole() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(agro), abi.encodeCall(agro.revokeRole, (agro.PRODUCER_ROLE(), producer)));
        _passAndExecute(t, v, c, "AGP-3: baja de productor");

        assertFalse(agro.hasRole(agro.PRODUCER_ROLE(), producer));
    }

    // ---------------------------------------------------------------
    // Casos que deben fallar
    // ---------------------------------------------------------------

    function test_ProposalDefeated_WithoutQuorum() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(agro), abi.encodeCall(agro.grantRole, (agro.PRODUCER_ROLE(), newProducer)));
        string memory desc = "AGP-4: sin quorum";
        uint256 id = _propose(t, v, c, desc);

        _toVoting();
        _vote(id, carol, FOR); // 10.000 AGT < quórum de 40.000 AGT
        _toVotingEnd();

        assertLt(10_000 ether, governor.quorum(governor.proposalSnapshot(id)));
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));

        vm.expectPartialRevert(IGovernor.GovernorUnexpectedProposalState.selector);
        governor.queue(t, v, c, keccak256(bytes(desc)));
        assertFalse(agro.hasRole(agro.PRODUCER_ROLE(), newProducer));
    }

    function test_ProposalDefeated_WhenMajorityVotesAgainst() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(agro), abi.encodeCall(agro.grantRole, (agro.PRODUCER_ROLE(), newProducer)));
        uint256 id = _propose(t, v, c, "AGP-5: rechazada");

        _toVoting();
        _vote(id, alice, AGAINST);
        _vote(id, bob, FOR);
        _toVotingEnd();

        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_RevertWhen_QueueBeforeVotingEnds() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(agro), abi.encodeCall(agro.grantRole, (agro.PRODUCER_ROLE(), newProducer)));
        string memory desc = "AGP-6: apurada";
        uint256 id = _propose(t, v, c, desc);
        _toVoting();
        _vote(id, alice, FOR);

        vm.expectPartialRevert(IGovernor.GovernorUnexpectedProposalState.selector);
        governor.queue(t, v, c, keccak256(bytes(desc)));
    }

    function test_RevertWhen_ExecuteBeforeTimelockDelay() public {
        address v2 = address(new AgroTraceV2Mock());
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(agro), abi.encodeCall(agro.upgradeToAndCall, (v2, "")));
        string memory desc = "AGP-7: upgrade sin esperar";
        bytes32 descHash = keccak256(bytes(desc));

        uint256 id = _propose(t, v, c, desc);
        _toVoting();
        _vote(id, alice, FOR);
        _toVotingEnd();
        governor.queue(t, v, c, descHash);

        // Inmediatamente después de encolar.
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        governor.execute(t, v, c, descHash);

        // Un segundo antes de que venza la demora.
        vm.warp(vm.getBlockTimestamp() + MIN_DELAY - 1);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        governor.execute(t, v, c, descHash);

        assertEq(agro.version(), "1.0.0");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Queued));
    }

    function test_RevertWhen_VotingTwice() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(agro), abi.encodeCall(agro.grantRole, (agro.PRODUCER_ROLE(), newProducer)));
        uint256 id = _propose(t, v, c, "AGP-8: doble voto");
        _toVoting();
        _vote(id, alice, FOR);

        vm.expectPartialRevert(IGovernor.GovernorAlreadyCastVote.selector);
        _vote(id, alice, FOR);
    }

    function test_VotesAfterSnapshotDoNotCount() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _single(address(agro), abi.encodeCall(agro.grantRole, (agro.PRODUCER_ROLE(), newProducer)));
        uint256 id = _propose(t, v, c, "AGP-9: snapshot");
        _toVoting();

        // Bob le pasa sus tokens a carol DESPUÉS del snapshot: carol no gana votos para esta propuesta.
        vm.prank(bob);
        token.transfer(carol, 300_000 ether);
        _vote(id, carol, FOR);
        (, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, 10_000 ether);
    }

    // ---------------------------------------------------------------
    // Script de deploy
    // ---------------------------------------------------------------

    function test_DeployScript_HandsOverEverything() public {
        uint256 key = 0xA11CE;
        address scriptDeployer = vm.addr(key);
        vm.setEnv("PRIVATE_KEY", vm.toString(key));
        vm.setEnv("PROXY_ADDRESS", vm.toString(address(0)));
        vm.setEnv("TOKEN_RECIPIENT", vm.toString(scriptDeployer));
        vm.setEnv("VOTING_PERIOD", "100");
        vm.setEnv("TIMELOCK_MIN_DELAY", "3600");

        DeployGovernance script = new DeployGovernance();
        DeployGovernance.Deployment memory d = script.run();

        assertEq(d.governor.votingDelay(), 1);
        assertEq(d.governor.votingPeriod(), 100);
        assertEq(d.governor.quorumNumerator(), 4);
        assertEq(d.timelock.getMinDelay(), 3600);
        assertEq(d.token.balanceOf(scriptDeployer), 1_000_000 ether);
        assertEq(d.token.delegates(scriptDeployer), scriptDeployer);
        assertTrue(d.agro.hasRole(d.agro.DEFAULT_ADMIN_ROLE(), address(d.timelock)));
        assertTrue(d.agro.hasRole(d.agro.UPGRADER_ROLE(), address(d.timelock)));
        assertFalse(d.agro.hasRole(d.agro.DEFAULT_ADMIN_ROLE(), scriptDeployer));
        assertFalse(d.agro.hasRole(d.agro.UPGRADER_ROLE(), scriptDeployer));
        assertFalse(d.timelock.hasRole(d.timelock.DEFAULT_ADMIN_ROLE(), scriptDeployer));
    }
}
