// A stand-in for the host Worker (src/host/protocol.ts) for browser tests:
// answers hello with a canned welcome and echoes each input datagram back as
// a snapshot datagram (same bytes, type byte 0x20). No sim.

/// <reference lib="webworker" />

import { Msg, PROTOCOL_VERSION, Reader, Writer, decodeHello, encodeWelcome } from "../../../../interfaces/ts/src/wire.ts";
import type { FromHost, ToHost } from "../../src/host/protocol.ts";

const post = (m: FromHost, transfer: Transferable[] = []): void => (self as unknown as Worker).postMessage(m, transfer);
const hex = (b: Uint8Array): string => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");

self.onmessage = async (ev: MessageEvent<ToHost>) => {
  const m = ev.data;
  switch (m.t) {
    case "start": {
      const h = new Uint8Array(await crypto.subtle.digest("SHA-256", m.map));
      post({ t: "ready", mapHash: hex(h), layoutHash: "0", maxPlayers: m.maxPlayers, cars: 0, carsHash: "" });
      return;
    }
    case "stream": {
      const b = new Uint8Array(m.msg);
      if (b[0] !== Msg.hello) return;
      const hello = decodeHello(new Reader(b));
      const w = new Writer(256);
      encodeWelcome(w, {
        protocol: PROTOCOL_VERSION, clientId: m.peer, resumeToken: new Uint8Array(16), serverTick: 0, tickHz: 30, snapshotHz: 20,
        inputBufferTicks: 2, redundancy: 8, maxPlayers: 16, configName: `fake t${hello.transport}`, slots: [m.peer & 15],
      });
      const out = w.finish().buffer as ArrayBuffer;
      post({ t: "stream", peer: m.peer, msg: out }, [out]);
      return;
    }
    case "datagram": {
      const b = new Uint8Array(m.msg);
      b[0] = Msg.snapshot;
      post({ t: "datagram", peer: m.peer, msg: b.buffer as ArrayBuffer }, [b.buffer as ArrayBuffer]);
      return;
    }
    case "stop":
      post({ t: "stopped" });
      return;
  }
};
