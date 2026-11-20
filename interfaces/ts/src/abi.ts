// I1. Sim ABI: the parts a TypeScript reader needs (units, ids, views).
// Frozen interface. Spec: interfaces/I1-sim-abi.md. Twin of zig/src/abi.zig.
// The shell does not call the sim directly; client/wasm does. These types
// let the debug overlay, tools and the renderer stub read state bytes.

export const ABI_VERSION = 1;
export const TICK_HZ = 30;

/** 16.16 fixed point, one block = 1.0. */
export const FX_ONE = 1 << 16;
export const fxToFloat = (v: number): number => v / FX_ONE;
/** For tools and tests only; the sim never sees floats. */
export const fxFromFloat = (v: number): number => Math.round(v * FX_ONE) | 0;

/** Binary angle: 65536 per turn, 0 = +x (east), growing toward +y (south). */
export const ANGLE_TURN = 65536;
export const angleToRadians = (a: number): number => ((a & 0xffff) / ANGLE_TURN) * 2 * Math.PI;

export const MAP_X = 256;
export const MAP_Y = 256;
export const MAP_Z = 8;

export const Kind = {
  car: 0,
  ped: 1,
  projectile: 2,
  pickup: 3,
  mapObject: 4,
  playerRow: 15,
} as const;
export type KindId = (typeof Kind)[keyof typeof Kind];

export const ComponentId = {
  transform: 1,
  velocity: 2,
  collider: 3,
  health: 4,
  controller: 5,
  vehicle: 6,
  pedestrian: 7,
  riding: 8,
  weapon: 9,
  projectile: 10,
  predicted: 11,
  appearance: 12,
} as const;

export const ColumnSpecial = {
  slot: 0x100,
  generation: 0x101,
  len: 0x102,
  playerRows: 0x103,
  tick: 0x104,
} as const;

export const Slot = { free: 0, alive: 1, spawning: 2, dying: 3 } as const;

export const ENTITY_NONE = 0xffffffff;

export const entityId = {
  make: (kind: number, index: number, gen: number): number =>
    ((index & 0xfff) | ((kind & 0xf) << 12) | ((gen & 0xffff) << 16)) >>> 0,
  index: (id: number): number => id & 0xfff,
  kind: (id: number): number => (id >>> 12) & 0xf,
  gen: (id: number): number => id >>> 16,
  handle: (id: number): number => id & 0xffff,
};

export interface ColumnDesc {
  kind: number;
  component: number;
  offset: number;
  stride: number;
  count: number;
}
export const COLUMN_DESC_SIZE = 16;

/** Read an array of ColumnDesc (as `views()` returns them) from memory. */
export function readColumnDescs(dv: DataView, offset: number, n: number): ColumnDesc[] {
  const out: ColumnDesc[] = [];
  for (let i = 0; i < n; i++) {
    const o = offset + i * COLUMN_DESC_SIZE;
    out.push({
      kind: dv.getUint8(o),
      component: dv.getUint16(o + 2, true),
      offset: dv.getUint32(o + 4, true),
      stride: dv.getUint32(o + 8, true),
      count: dv.getUint32(o + 12, true),
    });
  }
  return out;
}

// Frozen component layouts (byte offsets inside one element).
export interface Transform { x: number; y: number; z: number; heading: number }
export function readTransform(dv: DataView, o: number): Transform {
  return { x: dv.getInt32(o, true), y: dv.getInt32(o + 4, true), z: dv.getInt32(o + 8, true), heading: dv.getUint16(o + 12, true) };
}

export interface PlayerRow {
  ped: number; car: number; kills: number; deaths: number; score: number; respawnTimer: number; flags: number;
}
export const PlayerRowFlag = { active: 1, connected: 2 } as const;
export function readPlayerRow(dv: DataView, o: number): PlayerRow {
  return {
    ped: dv.getUint32(o, true), car: dv.getUint32(o + 4, true), kills: dv.getInt32(o + 8, true),
    deaths: dv.getInt32(o + 12, true), score: dv.getInt32(o + 16, true),
    respawnTimer: dv.getUint32(o + 20, true), flags: dv.getUint32(o + 24, true),
  };
}

/** Field layout used by the I3 delta codec: [name, bytes, signed]. Padding omitted. */
export type FieldSchema = readonly (readonly [string, 1 | 2 | 4, boolean])[];
export const TransformSchema: FieldSchema = [["x", 4, true], ["y", 4, true], ["z", 4, true], ["heading", 2, false]];
export const PlayerRowSchema: FieldSchema = [
  ["ped", 4, false], ["car", 4, false], ["kills", 4, true], ["deaths", 4, true],
  ["score", 4, true], ["respawnTimer", 4, false], ["flags", 4, false],
];
