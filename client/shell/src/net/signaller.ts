// Which signalling service the page uses for browser-hosted games.
//
// Default: BroadcastChannel (signal-bc.ts), which only reaches tabs of the
// same browser. A WebSocket signaller (signal-ws.ts, the Cloudflare room
// service) plugs in with registerSignaller("ws", ...); it is then picked when
// SIGNAL_URL is set or the page has ?signal=wss://... in its query.
// ?signal=bc forces BroadcastChannel.

import { BcSignaller } from "./signal-bc.ts";
import type { Signaller } from "./signal.ts";

/** Build-time default signalling URL (wss://...), or null for BroadcastChannel. */
export const SIGNAL_URL: string | null = null;

export type Role = "host" | "peer";
export type SignallerFactory = (role: Role, room: string, url: string) => Signaller | Promise<Signaller>;

const factories = new Map<string, SignallerFactory>();

/** Register an implementation for a URL scheme family ("ws" covers ws: and wss:). */
export function registerSignaller(kind: string, f: SignallerFactory): void {
  factories.set(kind, f);
}

/** The configured signalling URL: ?signal= wins over SIGNAL_URL. "bc" or nothing means BroadcastChannel. */
export function signalSetting(search: string = typeof location === "undefined" ? "" : location.search): string | null {
  const q = new URLSearchParams(search).get("signal");
  if (q) return q === "bc" ? null : q;
  return SIGNAL_URL;
}

export async function createSignaller(role: Role, room: string, search?: string): Promise<Signaller> {
  const url = signalSetting(search);
  if (!url) return role === "host" ? BcSignaller.host(room) : BcSignaller.peer(room);
  const kind = /^wss?:/i.test(url) ? "ws" : url.split(":")[0]!;
  const f = factories.get(kind);
  if (!f) throw new Error(`no signalling client for ${url} in this build`);
  return f(role, room, url);
}

/** A new room name: 8 characters of base32 (a-z, 2-7), as parseJoinHash expects. */
export function newRoom(): string {
  const abc = "abcdefghijklmnopqrstuvwxyz234567";
  return Array.from(crypto.getRandomValues(new Uint8Array(8)), (b) => abc[b & 31]).join("");
}

/** Whether the signalling in use only reaches this browser (the UI says so next to the link). */
export const signalIsLocal = (search?: string): boolean => !signalSetting(search);
