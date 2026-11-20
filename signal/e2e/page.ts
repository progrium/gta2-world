// Test page for e2e/run.ts: a host and a peer set up an RTCPeerConnection
// through the signalling Worker (client/shell/src/net/signal-ws.ts) and swap
// one message each over a data channel.

import { hostRoom, joinRoom } from "../../client/shell/src/net/signal-ws.ts";
import type { SignalMsg, Signaller } from "../../client/shell/src/net/signal.ts";

const log: string[] = [];
const note = (s: string) => {
  log.push(s);
  console.log(s);
};

function wireIce(pc: RTCPeerConnection, s: Signaller, to: string): void {
  pc.onicecandidate = (e) => s.send(to, { kind: "ice", candidate: e.candidate ? e.candidate.toJSON() : null });
}

async function onIce(pc: RTCPeerConnection, msg: SignalMsg): Promise<void> {
  if (msg.kind === "ice" && msg.candidate) await pc.addIceCandidate(msg.candidate);
}

/** Host: creates a room, answers one peer, waits for its greeting, replies, reports peer-left. */
let hostDone: Promise<string[]> | null = null;
async function runHost(base: string): Promise<string> {
  const { room, signaller: s } = await hostRoom(base);
  note(`host: room ${room}, ${s.ice.iceServers.length} ice server entries`);
  hostSignaller = s;
  const done = new Promise<string[]>((resolve, reject) => {
    const pcs = new Map<string, RTCPeerConnection>();
    let got = "";
    let left = false;
    s.onPeer = async (peer) => {
      note(`host: peer ${peer} arrived`);
      const pc = new RTCPeerConnection(s.ice);
      pcs.set(peer, pc);
      wireIce(pc, s, peer);
      const dc = pc.createDataChannel("s");
      dc.onmessage = (e) => {
        got = String(e.data);
        note(`host: got "${got}"`);
        dc.send("hello from host");
        if (left) resolve(log);
      };
      await pc.setLocalDescription(await pc.createOffer());
      s.send(peer, { kind: "offer", sdp: pc.localDescription!.sdp });
    };
    s.onMessage = async (from, msg) => {
      const pc = pcs.get(from);
      if (!pc) return;
      if (msg.kind === "answer") await pc.setRemoteDescription({ type: "answer", sdp: msg.sdp });
      else await onIce(pc, msg);
    };
    s.onPeerLeft = (peer) => {
      note(`host: peer ${peer} left signalling`);
      left = true;
      if (got) resolve(log);
    };
    s.onClose = (reason) => reject(new Error(`host closed: ${reason}`));
  });
  hostDone = done;
  done.catch(() => {});
  return room;
}

/** Peer: joins, answers the host's offer, greets over the data channel, closes signalling once open. */
async function runPeer(base: string, room: string): Promise<string[]> {
  const s = await joinRoom(base, room);
  note(`peer: joined ${room}`);
  const pc = new RTCPeerConnection(s.ice);
  wireIce(pc, s, "host");
  return new Promise((resolve, reject) => {
    s.onMessage = async (_from, msg) => {
      if (msg.kind === "offer") {
        await pc.setRemoteDescription({ type: "offer", sdp: msg.sdp });
        await pc.setLocalDescription(await pc.createAnswer());
        s.send("host", { kind: "answer", sdp: pc.localDescription!.sdp });
      } else await onIce(pc, msg);
    };
    s.onClose = (reason) => reject(new Error(`peer closed: ${reason}`));
    pc.ondatachannel = (e) => {
      const dc = e.channel;
      dc.onopen = () => {
        note(`peer: data channel "${dc.label}" open`);
        s.close(); // signalling for this peer is done
        dc.send("hello from peer");
      };
      dc.onmessage = (m) => {
        note(`peer: got "${m.data}"`);
        resolve(log);
      };
    };
  });
}

let hostSignaller: Signaller | null = null;
const closeHost = () => hostSignaller?.close();

let closedReason: Promise<string> | null = null;
/** Joins and stays; `closedReason()` then resolves with the reason the room closes. */
async function joinAndStay(base: string, room: string): Promise<void> {
  const s = await joinRoom(base, room);
  closedReason = new Promise<string>((resolve) => (s.onClose = resolve));
}

/** A join after the host left is refused with the server's reason. */
async function tryJoin(base: string, room: string): Promise<string> {
  try {
    await joinRoom(base, room);
    return "joined";
  } catch (e) {
    return (e as Error).message;
  }
}

Object.assign(window, {
  runHost,
  runPeer,
  tryJoin,
  closeHost,
  joinAndStay,
  hostDone: () => hostDone,
  closedReason: () => closedReason,
});
