// Cameras. Positions are in blocks with the sim's axes: x east, y south,
// z up. The renderer converts to GL space itself.

export interface CameraView {
  /// Eye and look-at point, sim axes, blocks.
  eye: [number, number, number];
  target: [number, number, number];
  /// Screen-up direction, sim axes. North (-y) for the top-down camera.
  up: [number, number, number];
  /// Vertical field of view, radians.
  fovY: number;
}

export interface FollowTarget {
  x: number;
  y: number;
  z?: number;
  /// Speed in blocks per second.
  speed?: number;
}

/// Top-down perspective camera that follows a target and pulls back as it
/// speeds up, then eases back down when it slows, as the original does.
/// Heights are blocks above the target.
export class ChaseCamera {
  fovY = (60 * Math.PI) / 180;
  baseHeight = 7;
  maxHeight = 15;
  /// Extra height per block/second of speed.
  heightPerSpeed = 0.6;
  /// Response rates (1/s): rising is quicker than settling back.
  riseRate = 2.0;
  fallRate = 0.6;
  height = 7;
  private x = 0;
  private y = 0;
  private z = 0;
  private placed = false;

  update(t: FollowTarget, dt: number): void {
    const z = t.z ?? 2;
    if (!this.placed) {
      this.x = t.x; this.y = t.y; this.z = z;
      this.height = this.baseHeight;
      this.placed = true;
    }
    this.x = t.x;
    this.y = t.y;
    this.z += (z - this.z) * (1 - Math.exp(-dt * 4));
    const want = Math.min(this.maxHeight, this.baseHeight + this.heightPerSpeed * Math.max(0, t.speed ?? 0));
    const rate = want > this.height ? this.riseRate : this.fallRate;
    this.height += (want - this.height) * (1 - Math.exp(-dt * rate));
  }

  /// Forget the last position, e.g. after a respawn or map change.
  reset(): void {
    this.placed = false;
  }

  view(): CameraView {
    return {
      eye: [this.x, this.y, this.z + this.height],
      target: [this.x, this.y, this.z],
      up: [0, -1, 0],
      fovY: this.fovY,
    };
  }
}

/// Free-flying debug camera (yaw/pitch), for looking at the map.
export class FreeCamera {
  x = 128;
  y = 140;
  z = 30;
  yaw = 0; // 0 looks north (-y)
  pitch = -1.2; // radians, negative looks down
  fovY = 1.0;

  forward(): [number, number, number] {
    const c = Math.cos(this.pitch);
    return [Math.sin(this.yaw) * c, -Math.cos(this.yaw) * c, Math.sin(this.pitch)];
  }

  move(forward: number, right: number, up: number): void {
    const f = this.forward();
    const r = [Math.cos(this.yaw), Math.sin(this.yaw)];
    this.x += f[0] * forward + r[0] * right;
    this.y += f[1] * forward + r[1] * right;
    this.z += f[2] * forward + up;
  }

  view(): CameraView {
    const f = this.forward();
    const pitchUp = Math.abs(this.pitch) > 1.55;
    return {
      eye: [this.x, this.y, this.z],
      target: [this.x + f[0], this.y + f[1], this.z + f[2]],
      // Straight down needs a horizontal up vector.
      up: pitchUp ? [Math.sin(this.yaw), -Math.cos(this.yaw), 0] : [0, 0, 1],
      fovY: this.fovY,
    };
  }
}
