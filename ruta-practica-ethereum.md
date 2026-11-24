# Ruta de práctica: contratos inteligentes Ethereum (testnet → mainnet)

Guía ampliada, paso a paso, para pasar de cero a desplegar en mainnet con criterio profesional.

---

## Paso 1 — Foundry: base local

**Objetivo:** tener un entorno de compilación y testing que corra en segundos, sin gastar gas.

- Instalá Foundry siguiendo la guía oficial (foundry.paradigm.xyz). Verificá con `forge --version` y `cast --version`.
- Creá el proyecto: `forge init mi-primer-contrato && cd mi-primer-contrato`.
- Escribí dos contratos de práctica:
  - Un **ERC-20** simple (nombre, símbolo, supply inicial, función `transfer`).
  - Un **contador** con `increment()` y `get()` para entender estado mutable.
- Corré `forge build` y asegurate de que compile sin warnings.
- Escribí tests en `test/` usando `forge-std/Test.sol`: al menos tres casos por contrato (camino feliz, revert con mensaje, edge case como transferir a address(0)).
- Ejecutá `forge test -vv` para ver el trace de cada test. Leé los logs: es tu primera forma de debuggear on-chain sin pagar nada.
- Bonus: probá `forge snapshot` para fijar el gas de cada test y detectar regresiones después.

**Criterio de salida:** todos los tests en verde, cero warnings de compilación, y entendés qué hace cada opcode del trace.

---

## Paso 2 — Sepolia: testnet

**Objetivo:** desplegar en una red pública de prueba donde el ETH no vale nada pero el comportamiento es idéntico a mainnet.

- Creá una cuenta nueva en MetaMask (o usá una existente) y anotalá la clave privada en papel, nunca en texto plano en el disco.
- Exportá la clave a una variable de entorno: `export SEPOLIA_PRIVATE_KEY=0x...` en tu `.bashrc` o `.zshrc`. Nunca la hardcodees en el contrato ni en scripts versionados.
- Conseguí ETH de prueba desde un faucet de Sepolia (por ejemplo, sepoliafaucet.com o el de Alchemy). Pedí el monto mínimo necesario: 0.1 ETH suele alcanzar para varios deploys.
- Desplegá con Foundry: `forge create --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY src/MiContrato.sol:MiContrato --verify --etherscan-api-key $ETHERSCAN_KEY`.
  - El flag `--verify` sube el código fuente a Etherscan automáticamente.
  - Necesitás una API key de Etherscan (gratis en etherscan.io).
- Abrí la URL que te devuelve el comando. Confirmá que el contrato aparece **verificado**: el código fuente es legible y público para cualquiera.
- Hacé una transacción de prueba desde la consola de Foundry (`cast send`) o desde Etherscan (botón Write Contract) para mover estado real en testnet.

**Criterio de salida:** contrato desplegado, verificado en Etherscan, y al menos una transacción de escritura ejecutada y confirmada.

---

## Paso 3 — Interacción programática

**Objetivo:** dejar de usar la UI y empezar a automatizar lecturas y escrituras, que es lo que hacen los agentes y las dApps.

- Creá un script en TypeScript con **ethers.js v6** (o viem si preferís algo más moderno y tipado).
- Conectate al RPC de Sepolia (Infura, Alchemy o un nodo propio).
- Implementá:
  - Una función de **lectura** (`view`/`pure`) usando `contract.functionName()` — no consume gas.
  - Una función de **escritura** usando `contract.functionName().populateTransaction()` + firmar + enviar + esperar el receipt.
- Manejá los tres estados de una tx: pending, mined, reverted. Leé el `receipt.status` (1 = éxito, 0 = revert).
- Bonus: escribí un listener de eventos con `contract.on("EventName", ...)` para reaccionar a Transfer o Increment en tiempo real.
- Probá el mismo script apuntando al RPC de mainnet (solo lectura) para ver datos reales sin riesgo.

**Criterio de salida:** un script que lee y escribe en Sepolia de forma repetible, con manejo de errores y logs claros.

---

## Paso 4 — Mainnet: montos reales chicos

**Objetivo:** sentir el costo real del gas y la fricción operativa antes de mover dinero serio.

- **Nunca** reutilices la clave de testnet en mainnet. Creá una cuenta dedicada con hardware wallet (Ledger o Trezor).
- Transferí ETH de un exchange a esa wallet. Empezá con el equivalente a 5-10 dólares.
- Desplegá el mismo contrato que ya testeaste en Sepolia. Anotá el gas usado y el precio en gwei del momento.
- Hacé la matemática: si un deploy te costó X dólares, ¿cuánto costaría con un contrato de 10x el tamaño? Esto te da intuición de por qué la optimización importa.
- Verificá en Etherscan igual que en testnet. La verificación en mainnet es aún más importante: la gente va a auditar tu código.
- Dejá la wallet con saldo residual chico. No la vacíes del todo: a veces necesitás gas para interacciones futuras.

**Criterio de salida:** un deploy en mainnet pagado de verdad, verificado, con el recibo de gas archivado y entendido.

---

## Paso 5 — Auditoría

**Objetivo:** que otra persona encuentre lo que vos no viste. Los bugs en mainnet no se parchean: se explotan.

- Antes de tocar mainnet con fondos reales, someté el contrato a **Code4rena** (competiciones gratis con hackers que compiten por premios) o a **Spearbit**.
- Si no hay competición activa, pedí review a compañeros del máster o a la comunidad de Discord de Foundry/Solidity. Un par de ojos frescos atrapan el 80% de los errores comunes.
- Revisá vos mismo con las checklist clásicas: reentrancia, overflow/underflow (menos crítico post-Solidity 0.8 pero no imposible), access control, front-running, y manejo de `msg.value`.
- Documentá cada hallazgo y su fix en un archivo `AUDITORIA.md` dentro del repo.

**Criterio de salida:** al menos un review externo documentado, con los issues encontrados y resueltos.

---

## Paso 6 — Optimización de gas

**Objetivo:** entender dónde se va la plata y cómo bajarla sin sacrificar seguridad.

- Corré `forge test --gas-report` y leé la tabla: te dice cuánto gas consume cada función.
- Reglas de oro:
  - **Packing de storage**: las variables de 32 bytes o menos se agrupan en un solo slot. Ordenalas de menor a mayor.
  - Evitá `string` en storage si podés usar `bytes32`.
  - Usá `calldata` en vez de `memory` para parámetros de solo lectura en funciones externas.
  - Evitá bucles con longitud dinámica sin límite superior.
- Compará el gas antes y después con `forge snapshot` y fijate el diff.
- Bonus: explorá el contrato desplegado en mainnet con **ethervm.io** o el debugger de Etherscan para ver el bytecode opcode por opcode.

**Criterio de salida:** un diff de gas documentado mostrando al menos un 10% de ahorro en una función crítica.

---

## Conceptos transversales

- **Proxies UUPS**: si un contrato tiene un bug en mainnet, no podés cambiarlo. Un proxy te deja actualizar la lógica manteniendo la misma dirección y el mismo estado. Estudiá OpenZeppelin Contracts Upgradeable.
- **Eventos**: cada cambio de estado importante debería emitir un evento. Son gratis de indexar para los indexadores y cuestan poco gas.
- **Revert strings**: usá `require(cond, "mensaje")` con mensajes cortos; cada byte del string cuesta gas.
- **Timelocks y multisigs**: para contratos con fondos, considerá un timelock (retraso antes de ejecutar cambios) o un multisig como dueño.

---

## Recursos

- Documentación oficial de Solidity: docs.soliditylang.org
- Libro "Mastering Ethereum": github.com/ethereumbook/ethereumbook
- Awesome Ethereum Security: github.com/crytic/awesome-ethereum-security
- EIPs: eips.ethereum.org (leé al menos EIP-20, EIP-1967 de proxies, EIP-712 de firmas)

---

*Última actualización: noviembre 2026. Contexto: máster en Blockchain + IA. Herramientas: Foundry, Hardhat, Solidity, Etherscan, Sepolia, Code4rena.*