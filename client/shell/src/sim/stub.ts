// Placeholder world so the shell can be driven before the sim lands
// (workstream E stub). It consumes real I2 frames exactly as the sim will
// (edges from prev_buttons, direct mode, handbrake) but it is a float toy:
// none of its numbers are GTA2 handling, and nothing here goes into sim/.

import { Button, type Frame } from "../input/i2.ts";

export interface Body {
  x: number;
  y: number;
  /** Radians, 0 = +x, clockwise on screen (I1 convention). */
  heading: number;
  speed: number;
}

export interface StubPlayer {
  ped: Body;
  car: Body;
  inVehicle: boolean;
  prevButtons: number;
  /** Set when the last tick hit a wall; read by the shell for rumble. */
  impact: number;
  /** Set on the tick the player got in or out. */
  toggled: boolean;
}

export const ARENA = 24; // blocks per side

const TURN_TO = (a: number): number => (a / 65536) * 2 * Math.PI;
const wrap = (a: number): number => Math.atan2(Math.sin(a), Math.cos(a));

export class StubWorld {
  tick = 0;
  players: StubPlayer[] = [];
  prev: StubPlayer[] = [];

  ensure(n: number): void {
    while (this.players.length < n) {
      const i = this.players.length;
      const c = ARENA / 2 + i * 2;
      this.players.push({
        ped: { x: c - 1.5, y: c, heading: -Math.PI / 2, speed: 0 },
        car: { x: c, y: c, heading: -Math.PI / 2, speed: 0 },
        inVehicle: false,
        prevButtons: 0,
        impact: 0,
        toggled: false,
      });
    }
  }

  step(frames: readonly Frame[]): void {
    this.ensure(frames.length);
    this.prev = this.players.map((p) => ({ ...p, ped: { ...p.ped }, car: { ...p.car } }));
    const dt = 1 / 30;
    frames.forEach((f, i) => {
      const p = this.players[i]!;
      const pressed = f.buttons & ~p.prevButtons;
      p.prevButtons = f.buttons;
      p.impact = 0;
      p.toggled = false;
      const steer = f.steer / 127;
      const thr = f.throttle / 127;

      if (pressed & Button.enterExit) {
        const d = Math.hypot(p.ped.x - p.car.x, p.ped.y - p.car.y);
        if (p.inVehicle) {
          p.inVehicle = false;
          p.ped.x = p.car.x + Math.cos(p.car.heading + Math.PI / 2) * 1.2;
          p.ped.y = p.car.y + Math.sin(p.car.heading + Math.PI / 2) * 1.2;
          p.ped.heading = p.car.heading;
          p.toggled = true;
        } else if (d < 2.5) {
          p.inVehicle = true;
          p.toggled = true;
        }
      }

      if (p.inVehicle) {
        const c = p.car;
        const hb = (f.buttons & Button.handbrakeJump) !== 0;
        c.speed += thr * (thr * c.speed < 0 ? 22 : 9) * dt;
        c.speed *= hb ? 0.9 : 0.985;
        c.speed = Math.max(-5, Math.min(14, c.speed));
        const grip = Math.min(1, Math.abs(c.speed) / 3);
        c.heading = wrap(c.heading + steer * 2.6 * grip * Math.sign(c.speed || 1) * dt * (hb ? 1.6 : 1));
        this.move(p, c, dt);
        p.ped.x = c.x;
        p.ped.y = c.y;
      } else {
        const b = p.ped;
        const run = (f.buttons & Button.run) !== 0 ? 1.8 : 1;
        if (f.buttons & Button.direct) {
          const target = TURN_TO(f.aim);
          const diff = wrap(target - b.heading);
          const rate = 12 * dt;
          b.heading = wrap(b.heading + Math.max(-rate, Math.min(rate, diff)));
          b.speed = Math.max(0, thr) * 3 * run;
        } else {
          b.heading = wrap(b.heading + steer * 4 * dt);
          b.speed = thr * 3 * run;
        }
        this.move(p, b, dt);
      }
    });
    this.tick++;
  }

  private move(p: StubPlayer, b: Body, dt: number): void {
    const nx = b.x + Math.cos(b.heading) * b.speed * dt;
    const ny = b.y + Math.sin(b.heading) * b.speed * dt;
    const cx = Math.max(0.5, Math.min(ARENA - 0.5, nx));
    const cy = Math.max(0.5, Math.min(ARENA - 0.5, ny));
    if (cx !== nx || cy !== ny) {
      p.impact = Math.abs(b.speed);
      if (p.inVehicle) b.speed *= -0.3;
    }
    b.x = cx;
    b.y = cy;
  }
}
