# Requirements Document

## Introduction

Hoy AgroTrace tiene un único admin (`DEFAULT_ADMIN_ROLE` + `UPGRADER_ROLE`) que puede cambiar la lógica del
contrato o dar y quitar permisos en cualquier momento. Esta feature reemplaza ese punto único de control por
**gobernanza on-chain**: un token de votos, un Governor y un TimelockController que pasa a ser el único
admin y upgrader del proxy. Así cada cambio sensible queda propuesto, votado y demorado de forma visible
antes de ejecutarse.

Los criterios de aceptación siguen EARS: las palabras clave (`When`, `If`, `While`, `Where`, `shall`) quedan
en inglés y el resto en español.

## Boundary Context

- **In scope**: token de votos AGT, AgroGovernor, TimelockController, traspaso de roles de AgroTrace, script
  de deploy de gobernanza, script de propuesta de upgrade, tests y documentación.
- **Out of scope**: cambios a la lógica de lotes y custodia de AgroTrace; distribución o venta del token;
  frontend de votación (se usa Tally, cast o el explorador); gobernanza cross-chain.
- **Adjacent expectations**: AgroTrace sigue usando `AccessControlUpgradeable` sin modificaciones; los 39
  tests existentes siguen pasando.

## Requirements

### Requirement 1: Token de votos
**Objective:** Como miembro de la comunidad AgroTrace, quiero un token con poder de voto delegable, para
participar de las decisiones sobre el contrato.

#### Acceptance Criteria
1. The AgroGovToken shall implementar ERC20 con extensiones ERC20Votes y ERC20Permit (EIP-2612).
2. The AgroGovToken shall emitir todo su suministro en el constructor a una dirección receptora y no exponer función de emisión posterior.
3. If la dirección receptora es la dirección cero, then the AgroGovToken shall revertir el despliegue.
4. While un holder no delegó su poder de voto, the AgroGovToken shall reportar cero votos para ese holder.
5. When un holder delega, the AgroGovToken shall registrar un checkpoint de votos en el bloque actual.

### Requirement 2: Governor
**Objective:** Como holder de AGT, quiero proponer y votar cambios sobre AgroTrace, para que ninguna persona sola decida.

#### Acceptance Criteria
1. The AgroGovernor shall contar votos A favor, En contra y Abstención según el poder de voto en el bloque del snapshot de la propuesta.
2. The AgroGovernor shall usar por defecto un voting delay de 1 bloque, un voting period de 50.400 bloques, un umbral de propuesta de 0 y un quórum del 4% del suministro total.
3. If al cerrar la votación los votos A favor más Abstención no alcanzan el quórum, then the AgroGovernor shall marcar la propuesta como Defeated.
4. If al cerrar la votación los votos A favor no superan a los votos En contra, then the AgroGovernor shall marcar la propuesta como Defeated.
5. If una cuenta intenta votar dos veces la misma propuesta, then the AgroGovernor shall revertir.
6. When una propuesta queda Succeeded, the AgroGovernor shall permitir encolarla en el TimelockController.
7. If se intenta encolar una propuesta que no está Succeeded, then the AgroGovernor shall revertir.

### Requirement 3: Timelock
**Objective:** Como usuario de AgroTrace, quiero una demora obligatoria entre la aprobación y la ejecución, para poder reaccionar ante un cambio que no me parezca.

#### Acceptance Criteria
1. The TimelockController shall aceptar operaciones solo del AgroGovernor (PROPOSER_ROLE y CANCELLER_ROLE).
2. The TimelockController shall aplicar una demora mínima configurable, de 1 día por defecto.
3. If se intenta ejecutar una operación antes de que venza la demora, then the TimelockController shall revertir.
4. When vence la demora de una operación encolada, the TimelockController shall permitir que cualquier cuenta la ejecute.
5. The TimelockController shall administrarse a sí mismo, sin ningún admin externo, al terminar el despliegue.

### Requirement 4: Traspaso de roles de AgroTrace
**Objective:** Como auditor, quiero que después del deploy ninguna wallet individual tenga privilegios, para eliminar el riesgo de centralización.

#### Acceptance Criteria
1. When termina el despliegue de gobernanza, the AgroTrace proxy shall tener al TimelockController como único titular de DEFAULT_ADMIN_ROLE y UPGRADER_ROLE.
2. When termina el despliegue de gobernanza, the script de deploy shall haber renunciado a todos los roles del deployer en AgroTrace y en el TimelockController.
3. If una cuenta distinta del TimelockController intenta un upgrade o un cambio de roles, then the AgroTrace proxy shall revertir con AccessControlUnauthorizedAccount.
4. If alguna post-condición del traspaso no se cumple, then the script de deploy shall revertir.

### Requirement 5: Cambios a través de la gobernanza
**Objective:** Como DAO, quiero ejecutar upgrades y gestionar roles operativos mediante propuestas, para mantener el contrato vivo sin un admin central.

#### Acceptance Criteria
1. When una propuesta de `upgradeToAndCall` se ejecuta, the AgroTrace proxy shall apuntar a la nueva implementación conservando dirección, lotes y roles.
2. When una propuesta de `grantRole` o `revokeRole` sobre un rol operativo se ejecuta, the AgroTrace proxy shall reflejar el cambio de rol.
3. Where una propuesta incluye varias acciones, the AgroGovernor shall ejecutarlas de forma atómica en el mismo orden.
4. The script de propuesta shall permitir proponer, encolar y ejecutar un upgrade con la misma descripción en los tres pasos.

### Requirement 6: Parametrización y verificación
**Objective:** Como desarrollador, quiero parámetros configurables y verificados, para probar rápido en local o Sepolia y usar valores seguros en mainnet.

#### Acceptance Criteria
1. The script de deploy shall leer voting delay, voting period, umbral, quórum, demora del timelock, receptor y suministro del token desde variables de entorno con valores por defecto.
2. Where se define PROXY_ADDRESS, the script de deploy shall reutilizar ese proxy en lugar de desplegar uno nuevo.
3. If el deployer no es admin del proxy indicado, then the script de deploy shall revertir antes de desplegar la gobernanza.
4. The suite de tests shall cubrir el ciclo propose → vote → queue → execute, la falta de quórum, la ejecución antes de la demora y el rechazo de llamadas directas tras el traspaso.
