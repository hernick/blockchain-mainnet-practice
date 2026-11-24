# Ruta de práctica: contratos inteligentes Ethereum (testnet → mainnet)

## 1. Foundry — base local
- Instalá Foundry.
- Creá un proyecto: `forge init`.
- Escribí un contrato simple (ERC-20 o un contador).
- Compilá y corré los tests con `forge test` hasta que estén en verde.

## 2. Sepolia — testnet
- Conseguí ETH de prueba desde un faucet de Sepolia.
- Desplegá con `forge create` usando tu clave privada en una variable de entorno (nunca hardcodeada).
- Verificá el contrato en Etherscan para que el código sea público e inspeccionable.

## 3. Interacción
- Desde la consola de Foundry o con un script en TypeScript usando ethers.js: llamá funciones de lectura y escritura.
- Observá cómo cambia el estado on-chain tras cada transacción.

## 4. Mainnet — montos reales chicos
- Repetí el deploy en mainnet con montos mínimos (tipo 1 dólar de ETH) para sentir el costo real del gas.
- Usá hardware wallet para las claves privadas: nunca en el código ni en variables de entorno subidas a GitHub.

## 5. Auditoría
- Antes de cualquier despliegue serio, pasalo por una auditoría gratis tipo Code4rena o un review de pares.

## 6. Optimización de gas
- Aprendé a leer el gas report de `forge` (`forge snapshot` / `forge test --gas-report`).
- Optimizá el storage: es donde se va la mayoría del costo.

## Conceptos clave
- **Proxies con patrón UUPS**: permiten corregir bugs sin perder la dirección ni el estado del contrato.
- **Gas**: un deploy mal optimizado puede costar cientos de dólares en fees en mainnet.
- **Riesgo**: en mainnet el error cuesta plata de verdad; por eso el ciclo local → testnet → auditoría → mainnet.

## Notas
- Fecha: noviembre 2026.
- Contexto: máster en Blockchain + Inteligencia Artificial.
- Herramientas: Foundry, Hardhat, Solidity, Etherscan, Sepolia, Code4rena.