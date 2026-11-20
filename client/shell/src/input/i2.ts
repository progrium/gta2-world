// The frozen I2 frame, re-exported so the shell has one import path for it.
// Spec: interfaces/I2-input-frame.md.
export {
  type Frame,
  Button,
  BUTTON_DEFINED_MASK,
  BUTTON_EDGE_MASK,
  FRAME_SIZE,
  angleFromVector,
  encodeFrame,
  decodeFrame,
  neutralFrame,
  quantizeAxis,
  radialDeadzone,
  sanitizeFrame,
  seqOf,
} from "../../../../interfaces/ts/src/input.ts";
