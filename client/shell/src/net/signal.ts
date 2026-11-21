// Contract for WebRTC signalling: how the host page and a joining page swap
// SDP and ICE candidates. Two implementations:
//   - BroadcastChannel (same browser, tabs on one machine): dev and tests.
//   - WebSocket to the Cloudflare signalling Worker in signal/ (rooms).
// Neither carries game traffic; once the data channels open, signalling for
// that peer is done.

export type SignalPeer = string;

export type SignalMsg =
  | { kind: "offer"; sdp: string }
  | { kind: "answer"; sdp: string }
  | { kind: "ice"; candidate: RTCIceCandidateInit | null }
  /** Peer -> host: WebRTC didn't connect; carry the channels over BroadcastChannel `gta2-pipe/<id>` instead (same-browser signalling only, net/pipe.ts). */
  | { kind: "pipe"; id: string }
  /** Host -> peer: the host refused or closed the join (room full, host left). */
  | { kind: "bye"; reason: string };

export interface IceConfig {
  iceServers: RTCIceServer[];
  /** "relay" hides IP addresses (relay-only rooms). */
  iceTransportPolicy?: RTCIceTransportPolicy;
}

export interface Signaller {
  /** For the host: a peer arrived in the room. For a peer: unused. */
  onPeer: ((peer: SignalPeer) => void) | null;
  /** For the host: a peer left the room before or after connecting. */
  onPeerLeft: ((peer: SignalPeer) => void) | null;
  /** A message from `from` ("host" when received by a peer). */
  onMessage: ((from: SignalPeer, msg: SignalMsg) => void) | null;
  /** The room closed (host gone, or the signalling connection dropped). */
  onClose: ((reason: string) => void) | null;
  /** True when both ends are tabs of this browser (BroadcastChannel signalling): the pipe fallback is allowed. */
  readonly local?: boolean;
  /** ICE servers to use, including TURN credentials when the service mints them. */
  readonly ice: IceConfig;
  /** Send to a peer (host side) or to "host" (peer side). */
  send(to: SignalPeer, msg: SignalMsg): void;
  close(): void;
}

/** Join link fragment: `#join/<room>.<maphash12>`, with `.p` when the room has police on. */
export const parseJoinHash = (hash: string): { room: string; mapHash12: string; police: boolean } | null => {
  const m = /^#join\/([a-z2-7]{8})\.([0-9a-f]{12})(\.p)?$/.exec(hash);
  return m ? { room: m[1], mapHash12: m[2], police: m[3] === ".p" } : null;
};
export const joinHash = (room: string, mapHashHex: string, police = false): string => `#join/${room}.${mapHashHex.slice(0, 12)}${police ? ".p" : ""}`;
