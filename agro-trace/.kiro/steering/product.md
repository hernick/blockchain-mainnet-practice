# Product Overview

AgroTrace es un registro on-chain de **lotes agrícolas** y de su **cadena de custodia**
(productor → acopiador → procesador → distribuidor → minorista) sobre Ethereum. Es el proyecto final del
Máster en Blockchain + IA de Hernán Figueroa (Buenos Aires, Argentina).

## Core Capabilities

- **Registro de lotes**: productor, coordenadas GPS (escaladas 1e6), fecha de cosecha, cultivo y
  certificaciones (bitmask) guardados on-chain en 4 slots de storage.
- **Cadena de custodia auditable**: cada traspaso emite `CustodyTransferred`; solo avanza una etapa por vez y
  el receptor debe tener el rol de esa etapa.
- **Control de acceso por roles**: un rol por eslabón de la cadena, más `DEFAULT_ADMIN_ROLE` y `UPGRADER_ROLE`.
- **Upgradeable (UUPS)**: se corrigen bugs sin perder la dirección del proxy ni el estado.
- **Gobernanza on-chain**: los roles sensibles (admin y upgrader) los tiene un `TimelockController`
  controlado por un `Governor` con token de votos; ninguna wallet individual puede cambiar el contrato.
- **Gobernanza del proceso**: cada cambio se especifica (spec-driven development con hermes-sdd), se
  implementa y se revisa en un tablero Hermes Kanban antes de llegar a una propuesta on-chain.

## Target Use Cases

- Consumidores o compradores que escanean un QR con el `lotId` y ven el historial del lote.
- Cooperativas y acopiadores que necesitan probar origen y certificaciones (orgánico, Non-GMO, etc.).
- Evaluación académica: demostrar buenas prácticas de seguridad, gas y gobernanza en un contrato real.

## Value Proposition

- Trazabilidad verificable sin depender de una base de datos central.
- Descentralización progresiva: de un admin único a una DAO con demoras visibles (timelock).
- Integración con IA vía `metadataHash` (informes de modelos guardados off-chain y anclados on-chain).

---
_Patrones y propósito, no un listado exhaustivo de funciones._
