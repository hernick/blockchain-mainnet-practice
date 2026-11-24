# Project Structure

## Organization Philosophy

Proyecto Foundry clásico separado por rol del archivo: `src/` (contratos desplegables), `test/` (tests y
mocks), `script/` (deploy y operaciones), `docs/` y `.kiro/` (proceso). Un contrato por archivo.

## Directory Patterns

### Contratos de dominio
**Location**: `src/`
**Purpose**: lógica de negocio upgradeable (AgroTrace).
**Example**: `src/AgroTrace.sol`

### Contratos de gobernanza
**Location**: `src/governance/`
**Purpose**: token de votos y Governor; NO upgradeables, composición de OpenZeppelin.
**Example**: `src/governance/AgroGovernor.sol`

### Tests y mocks
**Location**: `test/`, `test/mocks/`
**Purpose**: un archivo `*.t.sol` por área (dominio, gobernanza); mocks que simulan versiones futuras.
**Example**: `test/AgroGovernance.t.sol`, `test/mocks/AgroTraceV2Mock.sol`

### Scripts
**Location**: `script/`
**Purpose**: `forge script` parametrizados por variables de entorno (`.env.example` documenta cada una).
**Example**: `script/DeployGovernance.s.sol`, `script/ProposeUpgrade.s.sol`

### Proceso (spec-driven + Kanban)
**Location**: `.kiro/steering/`, `.kiro/specs/<feature>/`, `docs/`
**Purpose**: memoria del proyecto, specs por feature (requirements → design → tasks) y guías de proceso.

## Naming Conventions

- **Archivos Solidity**: PascalCase igual al contrato (`AgroGovToken.sol`).
- **Scripts**: `<Acción><Objeto>.s.sol`.
- **Tests**: `<Contrato o área>.t.sol`.
- **Specs**: kebab-case (`agro-governance`).
- **Propuestas de gobernanza**: descripción con prefijo `AGP-<n>:` (AgroTrace Governance Proposal).

## Import Organization

```solidity
// 1. forge-std / OpenZeppelin vía remappings
import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
// 2. Contratos propios con rutas relativas
import {AgroTrace} from "../src/AgroTrace.sol";
```

Siempre imports con nombre (`{X}`), nunca `import "archivo.sol";` a secas.

## Code Organization Principles

- Los contratos de dominio no conocen a la gobernanza: solo ven direcciones con roles. La DAO es "un admin más".
- `lib/`, `out/`, `cache/` y `broadcast/` de redes locales no se versionan.

---
_Patrones, no un árbol de archivos exhaustivo._
