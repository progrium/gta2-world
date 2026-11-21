// Same-browser fallback for browser-hosted games: when two tabs of one
// browser can't open a WebRTC connection to each other (seen on machines
// where Chrome's hidden local addresses don't resolve, for example macOS
// without the browser's Local Network permission), the joiner asks the host
// for a "pipe" instead: the same three channels (s, d, f) carried over a
// BroadcastChannel. Only used with BroadcastChannel signalling, which already
// means both tabs are in this browser.
//
// PipeChannel implements the part of RTCDataChannel that rtc.ts, hostPeers.ts
// and the lobby use, so the rest of the code doesn't know the difference.

type Label = "s" | "d" | "f";

interface Frame {
  from: string;
  hello?: true;
  bye?: true;
  c?: Label;
  data?: string | ArrayBuffer;
}

/** One end of a pipe: a BroadcastChannel shared by exactly two tabs. */
export class PipeEnd {
  readonly s: PipeChannel;
  readonly d: PipeChannel;
  readonly f: PipeChannel;
  /** Stands in for the RTCPeerConnection (connectionState, close). */
  readonly pc: RTCPeerConnection;
  private bc: BroadcastChannel;
  private me = Math.random().toString(36).slice(2);
  private seen = false;
  private closed = false;
  private retry: ReturnType<typeof setInterval>;
  private fakePc: { connectionState: RTCPeerConnectionState; onconnectionstatechange: (() => void) | null; sctp: null; close: () => void };

  constructor(id: string) {
    this.bc = new BroadcastChannel(`gta2-pipe/${id}`);
    const send = (f: Omit<Frame, "from">): void => {
      if (!this.closed) this.bc.postMessage({ ...f, from: this.me });
    };
    this.s = new PipeChannel("s", (data) => send({ c: "s", data }));
    this.d = new PipeChannel("d", (data) => send({ c: "d", data }));
    this.f = new PipeChannel("f", (data) => send({ c: "f", data }));
    this.fakePc = { connectionState: "connecting", onconnectionstatechange: null, sctp: null, close: () => this.close() };
    this.pc = this.fakePc as unknown as RTCPeerConnection;
    for (const ch of [this.s, this.d, this.f]) ch.closeHook = () => this.close();
    this.bc.onmessage = (ev) => {
      const m = ev.data as Frame;
      if (!m || m.from === this.me || this.closed) return;
      if (m.hello) {
        if (!this.seen) {
          this.seen = true;
          clearInterval(this.retry);
          send({ hello: true }); // the other side may have missed ours
          this.setState("connected");
          for (const ch of [this.s, this.d, this.f]) ch.open();
        }
      } else if (m.bye) this.close(false);
      else if (m.c && m.data !== undefined) ({ s: this.s, d: this.d, f: this.f })[m.c].deliver(m.data);
    };
    send({ hello: true });
    this.retry = setInterval(() => send({ hello: true }), 250);
  }

  private setState(st: RTCPeerConnectionState): void {
    this.fakePc.connectionState = st;
    this.fakePc.onconnectionstatechange?.();
  }

  close(tell = true): void {
    if (this.closed) return;
    if (tell) this.bc.postMessage({ from: this.me, bye: true });
    this.closed = true;
    clearInterval(this.retry);
    for (const ch of [this.s, this.d, this.f]) ch.shut();
    this.setState("closed");
    this.bc.close();
  }
}

export class PipeChannel extends EventTarget {
  readonly label: Label;
  readyState: RTCDataChannelState = "connecting";
  readonly bufferedAmount = 0;
  bufferedAmountLowThreshold = 0;
  binaryType: BinaryType = "arraybuffer";
  onmessage: ((ev: MessageEvent) => void) | null = null;
  onopen: ((ev: Event) => void) | null = null;
  onclose: ((ev: Event) => void) | null = null;
  closeHook: (() => void) | null = null;
  private out: (data: string | ArrayBuffer) => void;

  constructor(label: Label, out: (data: string | ArrayBuffer) => void) {
    super();
    this.label = label;
    this.out = out;
  }

  send(data: string | ArrayBuffer | ArrayBufferView): void {
    if (this.readyState !== "open") throw new DOMException("channel not open", "InvalidStateError");
    if (typeof data === "string" || data instanceof ArrayBuffer) this.out(data);
    else this.out(new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice().buffer);
  }

  close(): void {
    this.closeHook?.();
  }

  /** @internal */
  open(): void {
    if (this.readyState !== "connecting") return;
    this.readyState = "open";
    const ev = new Event("open");
    this.onopen?.(ev);
    this.dispatchEvent(ev);
  }

  /** @internal */
  deliver(data: string | ArrayBuffer): void {
    if (this.readyState !== "open") return;
    const ev = new MessageEvent("message", { data });
    this.onmessage?.(ev);
    this.dispatchEvent(ev);
  }

  /** @internal */
  shut(): void {
    if (this.readyState === "closed") return;
    this.readyState = "closed";
    const ev = new Event("close");
    this.onclose?.(ev);
    this.dispatchEvent(ev);
  }
}
