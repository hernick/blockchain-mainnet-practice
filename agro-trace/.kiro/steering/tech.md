# Technology Stack

## Architecture

Contratos Solidity sobre Ethereum (Sepolia para pruebas). AgroTrace corre detrás de un `ERC1967Proxy`
(patrón UUPS). La gobernanza es la composición estándar de OpenZeppelin: `ERC20Votes` →
`Governor` → `TimelockController` → AgroTrace.

## Core Technologies

- **Lenguaje**: Solidity `0.8.28` (pragma fija), `evm_version = cancun`, optimizer 200 runs.
- **Framework**: Foundry (forge, cast, anvil) con `forge-std` v1.17.0.
- **Librerías**: OpenZeppelin Contracts y Contracts Upgradeable **v5.7.0** (remappings explícitos).
- **Off-chain (opcional)**: ethers.js v6 (`examples/interact.mjs`).

## Key Libraries

- `AccessControlUpgradeable`, `UUPSUpgradeable`, `Initializable` (AgroTrace).
- `ERC20Votes`, `ERC20Permit` (AgroGovToken).
- `Governor` + `GovernorSettings`, `GovernorCountingSimple`, `GovernorVotes`,
  `GovernorVotesQuorumFraction`, `GovernorTimelockControl` (AgroGovernor).
- `TimelockController` (sin código propio: se usa tal cual).

## Development Standards

### Código
- Identificadores en inglés estándar de Solidity; comentarios, NatSpec y documentación en español.
- Custom errors en lugar de revert strings; `calldata` para entradas; storage namespaced ERC-7201.
- Sin código propio donde OpenZeppelin ya resuelve el problema (no reinventar Governor ni Timelock).

### Seguridad
- Toda acción privilegiada post-deploy pasa por propuesta + votación + timelock.
- El deployer renuncia a todos sus roles al final del deploy; el script verifica las post-condiciones.
- Nunca subir `.env` ni claves; en mainnet usar keystore cifrado o hardware wallet.

### Testing
- `forge test`: camino feliz, reverts por acceso, edge cases, fuzzing y ciclo completo de gobernanza.
- Nombres: `test_<Qué>`, `test_RevertWhen_<Condición>`, `testFuzz_<Qué>`.
- `forge fmt --check` y `forge build --sizes` en CI.

## Development Environment

### Common Commands
```bash
forge build          # compilar
forge test -vvv      # tests
forge fmt            # formato
forge snapshot       # línea base de gas
anvil                # nodo local para probar scripts
```

## Key Technical Decisions

- **UUPS** en vez de Transparent Proxy: proxy más barato; la autorización vive en `_authorizeUpgrade`.
- **Reloj por bloques** en el token y el Governor (default de `ERC20Votes`); demoras del timelock en segundos.
- **Governor no upgradeable**: si hay que cambiarlo, la DAO le da `PROPOSER_ROLE` a uno nuevo vía propuesta.
- **Suministro fijo de AGT**: sin `mint`, para que el poder de voto no se pueda inflar.

---
_Estándares y patrones, no todas las dependencias._
