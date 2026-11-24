// Ejemplo mínimo de interacción con AgroTrace usando ethers.js v6.
// Uso:
//   cd examples && npm install
//   RPC_URL=http://127.0.0.1:8545 PRIVATE_KEY=0x... PROXY_ADDRESS=0x... node interact.mjs
//
// La wallet tiene que tener PRODUCER_ROLE (en local, el admin se lo puede otorgar a sí mismo; ver más abajo).
import { ethers } from "ethers";

const { RPC_URL, PRIVATE_KEY, PROXY_ADDRESS } = process.env;
if (!RPC_URL || !PRIVATE_KEY || !PROXY_ADDRESS) {
  console.error("Faltan RPC_URL, PRIVATE_KEY o PROXY_ADDRESS");
  process.exit(1);
}

// ABI "humana": solo lo que usamos. También podés importar out/AgroTrace.sol/AgroTrace.json.
const abi = [
  "function PRODUCER_ROLE() view returns (bytes32)",
  "function hasRole(bytes32 role, address account) view returns (bool)",
  "function grantRole(bytes32 role, address account)",
  "function registerLot((int32 latitude, int32 longitude, uint64 harvestDate, bytes32 cropType, uint16 certifications, bytes32 metadataHash) input) returns (uint256)",
  "function getLot(uint256 lotId) view returns ((address producer, uint64 harvestDate, uint16 certifications, uint8 stage, address custodian, int32 latitude, int32 longitude, bytes32 cropType, bytes32 metadataHash))",
  "function version() view returns (string)",
  "event LotRegistered(uint256 indexed lotId, address indexed producer, bytes32 indexed cropType, int32 latitude, int32 longitude, uint64 harvestDate, uint16 certifications)",
  "event CustodyTransferred(uint256 indexed lotId, address indexed from, address indexed to, uint8 fromStage, uint8 toStage)",
];

const STAGES = ["Productor", "Acopiador", "Procesador", "Distribuidor", "Minorista"];
const toCoord = (deg) => Math.round(deg * 1e6); // grados -> int32 escalado 1e6

const provider = new ethers.JsonRpcProvider(RPC_URL);
// NonceManager evita errores de "nonce too low" al mandar varias txs seguidas.
const wallet = new ethers.NonceManager(new ethers.Wallet(PRIVATE_KEY, provider));
const account = await wallet.getAddress();
const agro = new ethers.Contract(PROXY_ADDRESS, abi, wallet);

console.log("Versión del contrato:", await agro.version());

// Si la wallet es admin pero todavía no es productora, se otorga el rol (solo para pruebas).
const producerRole = await agro.PRODUCER_ROLE();
if (!(await agro.hasRole(producerRole, account))) {
  console.log("Otorgando PRODUCER_ROLE a", account);
  await (await agro.grantRole(producerRole, account)).wait();
}

// Registrar un lote de soja orgánica en Pergamino (Bs. As.)
const tx = await agro.registerLot({
  latitude: toCoord(-33.889444),
  longitude: toCoord(-60.573611),
  harvestDate: Math.floor(Date.UTC(2025, 2, 15) / 1000),
  cropType: ethers.encodeBytes32String("SOJA"),
  certifications: 1 | 16, // CERT_ORGANIC | CERT_NON_GMO
  metadataHash: ethers.id("ipfs://bafy...informe-ia"),
});
const receipt = await tx.wait();
const event = receipt.logs.map((l) => agro.interface.parseLog(l)).find((e) => e?.name === "LotRegistered");
const lotId = event.args.lotId;
console.log(`Lote #${lotId} registrado. Gas usado: ${receipt.gasUsed}`);

const lot = await agro.getLot(lotId);
console.log({
  productor: lot.producer,
  custodio: lot.custodian,
  etapa: STAGES[Number(lot.stage)],
  cultivo: ethers.decodeBytes32String(lot.cropType),
  lat: Number(lot.latitude) / 1e6,
  lon: Number(lot.longitude) / 1e6,
  cosecha: new Date(Number(lot.harvestDate) * 1000).toISOString().slice(0, 10),
  organico: (Number(lot.certifications) & 1) !== 0,
});

// Historial de custodia del lote, leído desde los eventos (no desde storage).
const history = await agro.queryFilter(agro.filters.CustodyTransferred(lotId), 0);
console.log(`Transferencias de custodia: ${history.length}`);
for (const h of history) {
  console.log(`  ${STAGES[Number(h.args.fromStage)]} -> ${STAGES[Number(h.args.toStage)]} (${h.args.to})`);
}
