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
  /// Velocity in blocks per tick (the sim's 30 ticks a second).
  vx?: number;
  vy?: number;
  /// Speed in blocks per second, when no velocity is given.
  speed?: number;
  /// Following a car (lift and lead-ahead apply), not a ped on foot.
  inCar?: boolean;
  /// The subject is dead (wasted or busted): the camera pulls far back
  /// (camera.md 3.2, zoom ≈3.55 against the default ≈0.887).
  dead?: boolean;
  /// The followed car's driver is being chased (police or a chase task):
  /// raises the suspicion counter that shortens the lead (camera.md 3.3).
  chased?: boolean;
  /// Script elevation offset in blocks, 0-20 in steps of 0.5 (camera.md 3.6).
  elevation?: number;
}

/// Top-down camera after docs/behaviour/camera.md, stepped at the sim's 30
/// ticks a second and interpolated between ticks for drawing.
///
/// - In a car, with s = 16 x speed (blocks a tick), the camera lifts by s
///   once s passes 1.5, and leads ahead along the direction of travel:
///   240 screen units north-south, 180 east-west, times its height.
/// - x and y approach the target with speed growing 1/64 a tick, capped at
///   height x 3/16, stopping dead when moving away; height rises with step
///   1/128 (cap 5/8) and falls with step 1/640 (cap 5/64), so it climbs
///   quickly and sinks slowly.
/// - The target set on one tick is used on the next.
/// - An explosion shakes it by 1/8, negated and x 0.75 every tick.
///
/// Heights are blocks of eye above the subject. The notes' camera height is
/// GTA2's own zoom scale; ours is a perspective eye, so the base height
/// (`baseHeight`) and the screen-unit scale of the lead (`leadScale`) are
/// ours, as is fading the lead in with speed so a parked car keeps the view
/// centred.
export class ChaseCamera {
  fovY = (60 * Math.PI) / 180;
  baseHeight = 7;
  maxHeight = 21;
  /// Blocks of lead per screen unit, per block of camera height.
  leadScale = 1 / (64 * 8);
  /// Speed (blocks a tick) at which the lead reaches its full length.
  leadFullSpeed = 0.06;
  /// Height factor while dead: the notes' dead zoom over the default.
  deadFactor = 3.55 / 0.887;
  /// Suspicion, 0-80, counted a tick (camera.md 3.3).
  suspicion = 0;
  height = 7;
  private x = 0;
  private y = 0;
  private z = 0;
  private vx = 0;
  private vy = 0;
  private vh = 0;
  private shakeV = 0;
  /// The previous tick's target, used this tick (the notes' one-tick lag).
  private tx = 0;
  private ty = 0;
  private th = 7;
  /// The state at the last tick, for interpolation.
  private px = 0;
  private py = 0;
  private ph = 7;
  private acc = 0;
  private placed = false;

  update(t: FollowTarget, dt: number): void {
    const z = t.z ?? 2;
    let vx = t.vx ?? 0;
    let vy = t.vy ?? 0;
    if (t.vx === undefined && t.speed) {
      vx = t.speed / 30;
      vy = 0;
    }
    const speed = Math.hypot(vx, vy);
    // Target: lift and lead in a car.
    let h = this.baseHeight;
    let lx = 0;
    let ly = 0;
    if (t.dead) h *= this.deadFactor;
    else if (t.inCar) {
      const s = 16 * speed;
      if (s > 1.5) h += s;
      if (speed > 1e-4) {
        const ns = Math.abs(vy) > Math.abs(vx);
        const sus = 1 - Math.min(this.suspicion, 64) / 128;
        const dist = (ns ? 240 : 180) * sus * this.leadScale * h * Math.min(1, speed / this.leadFullSpeed);
        lx = (vx / speed) * dist;
        ly = (vy / speed) * dist;
      }
    }
    h = Math.min(t.dead ? this.baseHeight * this.deadFactor : this.maxHeight, h) + Math.max(0, Math.min(20, t.elevation ?? 0));
    if (!this.placed) {
      this.x = this.px = this.tx = t.x + lx;
      this.y = this.py = this.ty = t.y + ly;
      this.z = z;
      this.height = this.ph = this.th = h;
      this.vx = this.vy = this.vh = this.shakeV = 0;
      this.acc = 0;
      this.placed = true;
    }
    this.acc += dt * 30;
    let steps = 0;
    while (this.acc >= 1 && steps < 8) {
      this.acc -= 1;
      steps++;
      this.px = this.x;
      this.py = this.y;
      this.ph = this.height;
      this.suspicion = Math.max(0, Math.min(80, this.suspicion + (t.chased && t.inCar ? 1 : -1)));
      this.tick();
      this.tx = t.x + lx;
      this.ty = t.y + ly;
      this.th = h;
    }
    if (steps === 8) this.acc = 0;
    // The subject's floor height is followed directly (the notes keep the
    // camera a fixed distance above it).
    this.z = z;
  }

  private tick(): void {
    const cap = (this.height * 3) / 16;
    [this.x, this.vx] = approach(this.x, this.vx, this.tx, 1 / 64, cap);
    [this.y, this.vy] = approach(this.y, this.vy, this.ty, 1 / 64, cap);
    const rising = this.th > this.height;
    [this.height, this.vh] = approach(this.height, this.vh, this.th, rising ? 1 / 128 : 1 / 640, rising ? 5 / 8 : 5 / 64);
    if (this.shakeV !== 0) {
      this.x += this.shakeV;
      this.y += this.shakeV;
      this.height = Math.max(0, this.height + this.shakeV);
      this.shakeV *= -0.75;
      if (Math.abs(this.shakeV) < 1 / 512) this.shakeV = 0;
    }
  }

  /// An explosion: shake of strength 8 (1/8 block).
  shake(strength = 8): void {
    this.shakeV = strength / 64;
  }

  /// Forget the last position, e.g. after a respawn or map change.
  reset(): void {
    this.placed = false;
    this.suspicion = 0;
  }

  view(): CameraView {
    const a = Math.min(1, this.acc);
    const x = this.px + (this.x - this.px) * a;
    const y = this.py + (this.y - this.py) * a;
    const h = this.ph + (this.height - this.ph) * a;
    return {
      eye: [x, y, this.z + h],
      target: [x, y, this.z],
      up: [0, -1, 0],
      fovY: this.fovY,
    };
  }
}

/// One axis of the camera's smoothing (camera.md 3.4): the speed toward the
/// target grows by `step` a tick up to `cap`, landing exactly on the target
/// rather than overshooting, and drops to 0 when moving away from it.
function approach(pos: number, vel: number, target: number, step: number, cap: number): [number, number] {
  const d = target - pos;
  if (d === 0) return [pos, 0];
  const dir = Math.sign(d);
  if (vel * dir < 0) vel = 0;
  vel = dir * Math.min(Math.abs(vel) + step, cap);
  if (Math.abs(vel) >= Math.abs(d)) return [target, vel];
  return [pos + vel, vel];
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
