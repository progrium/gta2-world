// WebGL2 renderer for the map and entity sprites. It owns no frame loop and
// no canvas sizing policy: the host calls resize() and draw().
//
// Data comes from the Zig side (client/render/src) as flat buffers:
//   - StyleData: raw style chunks plus the sprite table (style.zig).
//   - MapMeshData: 16-byte vertices in 16x16-block chunks (mesh.zig).
//   - instances: 24-byte render-list records (list.zig).

import type { CameraView } from './camera.js';
import { boxVisible, frustumPlanes, lookAt, multiply, perspective, type Vec3 } from './mat.js';
import { mapFS, mapVS, spriteFS, spriteVS } from './shaders.js';

export const VERTEX_BYTES = 16;
export const CHUNK_BYTES = 16;
export const INSTANCE_BYTES = 24;
const CHUNKS_ACROSS = 16;
const CHUNK_BLOCKS = 16;
const SPRITE_TABLE_WIDTH = 64;

export interface StyleData {
  /// TILE chunk: 256x256-byte pages of 16 tiles.
  tiles: Uint8Array;
  /// SPRG chunk: 256x256-byte pages.
  spritePages: Uint8Array;
  /// PPAL chunk: 64 palettes x 256 entries per 64 KB page, B,G,R,_.
  ppal: Uint8Array;
  /// PALX: 16384 virtual -> physical palette numbers.
  palx: Uint16Array;
  /// Sprite table from style.zig: x, y, layer, w | h << 8 per sprite,
  /// 64 sprites per row.
  spriteTable: Uint16Array;
  /// Virtual palette bases for tiles and sprites (PALB).
  tilePaletteBase: number;
  spritePaletteBase: number;
}

export interface MapMeshData {
  vertices: Uint8Array;
  /// 256 chunk records: first u32, count u32, cx u16, cy u16, minZ i16, maxZ i16.
  chunks: Uint8Array;
  /// Tile animations from the map (demo_wasm.zig layout), optional.
  anims?: Uint16Array;
}

export interface Viewport {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface DrawStats {
  chunksDrawn: number;
  drawCalls: number;
  triangles: number;
  sprites: number;
}

interface ChunkRec {
  first: number;
  count: number;
  min: Vec3;
  max: Vec3;
}

interface Anim {
  base: number;
  frameRate: number;
  tiles: number[];
}

function compile(gl: WebGL2RenderingContext, vs: string, fs: string): WebGLProgram {
  const sh = (type: number, src: string) => {
    const s = gl.createShader(type)!;
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s) ?? 'shader');
    return s;
  };
  const p = gl.createProgram()!;
  gl.attachShader(p, sh(gl.VERTEX_SHADER, vs));
  gl.attachShader(p, sh(gl.FRAGMENT_SHADER, fs));
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p) ?? 'link');
  return p;
}

function nearestTexture(gl: WebGL2RenderingContext, target: number): WebGLTexture {
  const t = gl.createTexture()!;
  gl.bindTexture(target, t);
  gl.texParameteri(target, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(target, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(target, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(target, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  return t;
}

export class Renderer {
  readonly gl: WebGL2RenderingContext;
  /// Daylight level and how strongly the map's coloured lights add on top.
  lighting = { ambient: 1.0, lightGain: 0.35 };
  clearColour: [number, number, number] = [0.05, 0.06, 0.08];
  near = 0.5;
  far = 400;
  lastStats: DrawStats = { chunksDrawn: 0, drawCalls: 0, triangles: 0, sprites: 0 };

  private mapProg: WebGLProgram;
  private spriteProg: WebGLProgram;
  private mapVao: WebGLVertexArrayObject;
  private mapVbo: WebGLBuffer;
  private extraVao: WebGLVertexArrayObject;
  private extraVbo: WebGLBuffer;
  private extraCount = 0;
  private spriteVao: WebGLVertexArrayObject;
  private instanceVbo: WebGLBuffer;
  private idxTex: WebGLTexture;
  private palxTex: WebGLTexture;
  private ppalTex: WebGLTexture;
  private spriteTex: WebGLTexture;
  private animTex: WebGLTexture;
  private animTable = new Uint16Array(1024);
  private anims: Anim[] = [];
  private chunks: ChunkRec[] = [];
  private style: StyleData | null = null;
  private instanceCapacity = 0;
  private mapU: Record<string, WebGLUniformLocation | null>;
  private spriteU: Record<string, WebGLUniformLocation | null>;

  constructor(canvasOrGl: HTMLCanvasElement | OffscreenCanvas | WebGL2RenderingContext) {
    const gl = 'getContext' in canvasOrGl
      ? (canvasOrGl.getContext('webgl2', { antialias: false, powerPreference: 'high-performance' }) as WebGL2RenderingContext | null)
      : canvasOrGl;
    if (!gl) throw new Error('WebGL2 not available');
    this.gl = gl;

    this.mapProg = compile(gl, mapVS, mapFS);
    this.spriteProg = compile(gl, spriteVS, spriteFS);
    const uniforms = (p: WebGLProgram, names: string[]) =>
      Object.fromEntries(names.map((n) => [n, gl.getUniformLocation(p, n)]));
    const shared = ['u_vp', 'u_idx', 'u_palx', 'u_ppal', 'u_ambient', 'u_lightGain'];
    this.mapU = uniforms(this.mapProg, [...shared, 'u_anim', 'u_tileBase']);
    this.spriteU = uniforms(this.spriteProg, [...shared, 'u_sprites', 'u_spriteBase']);

    // Map vertices, and a small second buffer of the same layout for faces
    // that change every frame (door leaves).
    const ml = (n: string) => gl.getAttribLocation(this.mapProg, n);
    const mapVertexArray = (vbo: WebGLBuffer): WebGLVertexArrayObject => {
      const vao = gl.createVertexArray()!;
      gl.bindVertexArray(vao);
      gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
      gl.enableVertexAttribArray(ml('a_pos'));
      gl.vertexAttribPointer(ml('a_pos'), 3, gl.SHORT, false, VERTEX_BYTES, 0);
      gl.enableVertexAttribArray(ml('a_uv'));
      gl.vertexAttribPointer(ml('a_uv'), 2, gl.UNSIGNED_BYTE, false, VERTEX_BYTES, 6);
      gl.enableVertexAttribArray(ml('a_tile'));
      gl.vertexAttribIPointer(ml('a_tile'), 1, gl.UNSIGNED_SHORT, VERTEX_BYTES, 8);
      gl.enableVertexAttribArray(ml('a_fs'));
      gl.vertexAttribIPointer(ml('a_fs'), 2, gl.UNSIGNED_BYTE, VERTEX_BYTES, 10);
      gl.enableVertexAttribArray(ml('a_light'));
      gl.vertexAttribPointer(ml('a_light'), 3, gl.UNSIGNED_BYTE, true, VERTEX_BYTES, 12);
      return vao;
    };
    this.mapVbo = gl.createBuffer()!;
    this.mapVao = mapVertexArray(this.mapVbo);
    this.extraVbo = gl.createBuffer()!;
    this.extraVao = mapVertexArray(this.extraVbo);

    // Sprite quads: one static corner buffer, one instance buffer.
    this.spriteVao = gl.createVertexArray()!;
    gl.bindVertexArray(this.spriteVao);
    const sl = (n: string) => gl.getAttribLocation(this.spriteProg, n);
    const corners = gl.createBuffer()!;
    gl.bindBuffer(gl.ARRAY_BUFFER, corners);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-0.5, -0.5, 0.5, -0.5, -0.5, 0.5, 0.5, 0.5]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(sl('a_corner'));
    gl.vertexAttribPointer(sl('a_corner'), 2, gl.FLOAT, false, 8, 0);
    this.instanceVbo = gl.createBuffer()!;
    gl.bindBuffer(gl.ARRAY_BUFFER, this.instanceVbo);
    gl.enableVertexAttribArray(sl('i_pose'));
    gl.vertexAttribPointer(sl('i_pose'), 4, gl.FLOAT, false, INSTANCE_BYTES, 0);
    gl.vertexAttribDivisor(sl('i_pose'), 1);
    gl.enableVertexAttribArray(sl('i_look'));
    // sprite u16, palette u16, kind u8 + flags u8, pad u16.
    gl.vertexAttribIPointer(sl('i_look'), 4, gl.UNSIGNED_SHORT, INSTANCE_BYTES, 16);
    gl.vertexAttribDivisor(sl('i_look'), 1);
    gl.bindVertexArray(null);

    this.idxTex = nearestTexture(gl, gl.TEXTURE_2D_ARRAY);
    this.palxTex = nearestTexture(gl, gl.TEXTURE_2D);
    this.ppalTex = nearestTexture(gl, gl.TEXTURE_2D);
    this.spriteTex = nearestTexture(gl, gl.TEXTURE_2D);
    this.animTex = nearestTexture(gl, gl.TEXTURE_2D);
    this.resetAnimTable();
  }

  setStyle(s: StyleData): void {
    const gl = this.gl;
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    const page = 256 * 256;
    const tileLayers = Math.ceil(s.tiles.length / page);
    const spriteLayers = Math.ceil(s.spritePages.length / page);
    const layers = Math.max(1, tileLayers + spriteLayers);
    const idx = new Uint8Array(layers * page);
    idx.set(s.tiles, 0);
    idx.set(s.spritePages, tileLayers * page);
    gl.bindTexture(gl.TEXTURE_2D_ARRAY, this.idxTex);
    gl.texImage3D(gl.TEXTURE_2D_ARRAY, 0, gl.R8UI, 256, 256, layers, 0, gl.RED_INTEGER, gl.UNSIGNED_BYTE, idx);

    gl.bindTexture(gl.TEXTURE_2D, this.palxTex);
    const palx = new Uint16Array(128 * 128);
    palx.set(s.palx.subarray(0, palx.length));
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R16UI, 128, 128, 0, gl.RED_INTEGER, gl.UNSIGNED_SHORT, palx);

    gl.bindTexture(gl.TEXTURE_2D, this.ppalTex);
    const ppalRows = Math.max(1, Math.ceil(s.ppal.length / (64 * 4)));
    const ppal = new Uint8Array(ppalRows * 64 * 4);
    ppal.set(s.ppal);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 64, ppalRows, 0, gl.RGBA, gl.UNSIGNED_BYTE, ppal);

    gl.bindTexture(gl.TEXTURE_2D, this.spriteTex);
    const rows = Math.max(1, Math.ceil(s.spriteTable.length / (SPRITE_TABLE_WIDTH * 4)));
    const table = new Uint16Array(rows * SPRITE_TABLE_WIDTH * 4);
    table.set(s.spriteTable);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16UI, SPRITE_TABLE_WIDTH, rows, 0, gl.RGBA_INTEGER, gl.UNSIGNED_SHORT, table);
    this.style = s;
  }

  setMap(m: MapMeshData): void {
    const gl = this.gl;
    gl.bindBuffer(gl.ARRAY_BUFFER, this.mapVbo);
    gl.bufferData(gl.ARRAY_BUFFER, m.vertices, gl.STATIC_DRAW);
    const dv = new DataView(m.chunks.buffer, m.chunks.byteOffset, m.chunks.byteLength);
    this.chunks = [];
    for (let o = 0; o + CHUNK_BYTES <= m.chunks.byteLength; o += CHUNK_BYTES) {
      const cx = dv.getUint16(o + 8, true), cy = dv.getUint16(o + 10, true);
      // Bounds in GL space (x, z up, y south), blocks.
      this.chunks.push({
        first: dv.getUint32(o, true),
        count: dv.getUint32(o + 4, true),
        min: [cx * CHUNK_BLOCKS, dv.getInt16(o + 12, true) / 64, cy * CHUNK_BLOCKS],
        max: [(cx + 1) * CHUNK_BLOCKS, dv.getInt16(o + 14, true) / 64, (cy + 1) * CHUNK_BLOCKS],
      });
    }
    if (this.chunks.length !== CHUNKS_ACROSS * CHUNKS_ACROSS) console.warn(`[render] ${this.chunks.length} chunks`);
    this.anims = [];
    const a = m.anims;
    if (a && a.length > 0) {
      let k = 1;
      for (let i = 0; i < a[0]; i++) {
        const len = a[k + 3];
        this.anims.push({ base: a[k], frameRate: Math.max(1, a[k + 1]), tiles: Array.from(a.subarray(k + 4, k + 4 + len)) });
        k += 4 + len;
      }
    }
    this.resetAnimTable();
  }

  /// Map faces that change from frame to frame (door leaves), in the map
  /// vertex layout. Drawn with the map, never culled; empty clears them.
  setExtraFaces(vertices: Uint8Array): void {
    const gl = this.gl;
    this.extraCount = Math.floor(vertices.byteLength / VERTEX_BYTES);
    if (this.extraCount === 0) return;
    gl.bindBuffer(gl.ARRAY_BUFFER, this.extraVbo);
    gl.bufferData(gl.ARRAY_BUFFER, vertices, gl.DYNAMIC_DRAW);
  }

  resize(cssWidth: number, cssHeight: number, dpr = 1): void {
    const c = this.gl.canvas;
    const r = Math.min(dpr, 2);
    const w = Math.max(1, Math.floor(cssWidth * r)), h = Math.max(1, Math.floor(cssHeight * r));
    if (c.width !== w || c.height !== h) {
      c.width = w;
      c.height = h;
    }
  }

  private resetAnimTable(): void {
    for (let i = 0; i < 1024; i++) this.animTable[i] = i;
    this.uploadAnimTable();
  }

  private uploadAnimTable(): void {
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.animTex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R16UI, 1024, 1, 0, gl.RED_INTEGER, gl.UNSIGNED_SHORT, this.animTable);
  }

  /// Animated tiles: `frameRate` is read as game frames (30 per second)
  /// per animation frame, looping. To be checked against the game.
  private updateAnims(timeSec: number): void {
    if (this.anims.length === 0) return;
    const gameFrame = Math.floor(timeSec * 30);
    let changed = false;
    for (const a of this.anims) {
      if (a.tiles.length === 0 || a.base >= 1024) continue;
      const t = a.tiles[Math.floor(gameFrame / a.frameRate) % a.tiles.length];
      if (this.animTable[a.base] !== t) {
        this.animTable[a.base] = t;
        changed = true;
      }
    }
    if (changed) this.uploadAnimTable();
  }

  /// Draws one view. `instances` holds `count` 24-byte render-list records.
  /// Pass a viewport for split-screen; the default is the whole canvas.
  draw(view: CameraView, instances: Uint8Array | null, count: number, timeSec: number, viewport?: Viewport, clear = true): DrawStats {
    const gl = this.gl;
    const vp = viewport ?? { x: 0, y: 0, w: gl.canvas.width, h: gl.canvas.height };
    const stats: DrawStats = { chunksDrawn: 0, drawCalls: 0, triangles: 0, sprites: 0 };
    gl.viewport(vp.x, vp.y, vp.w, vp.h);
    if (clear) {
      gl.enable(gl.SCISSOR_TEST);
      gl.scissor(vp.x, vp.y, vp.w, vp.h);
      gl.clearColor(...this.clearColour, 1);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      gl.disable(gl.SCISSOR_TEST);
    }
    const s = this.style;
    if (!s) return stats;

    const toGl = (v: [number, number, number]): Vec3 => [v[0], v[2], v[1]];
    const proj = perspective(view.fovY, vp.w / vp.h, this.near, this.far);
    const vpm = multiply(proj, lookAt(toGl(view.eye), toGl(view.target), toGl(view.up)));
    this.updateAnims(timeSec);

    gl.enable(gl.DEPTH_TEST);
    gl.depthFunc(gl.LEQUAL);
    gl.disable(gl.CULL_FACE);
    gl.disable(gl.BLEND);

    const bindShared = (u: Record<string, WebGLUniformLocation | null>) => {
      gl.uniformMatrix4fv(u.u_vp, false, vpm);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D_ARRAY, this.idxTex); gl.uniform1i(u.u_idx, 0);
      gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, this.palxTex); gl.uniform1i(u.u_palx, 1);
      gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D, this.ppalTex); gl.uniform1i(u.u_ppal, 2);
      gl.uniform1f(u.u_ambient, this.lighting.ambient);
      gl.uniform1f(u.u_lightGain, this.lighting.lightGain);
    };

    // Map: frustum-cull chunks, merge runs of visible chunks into one call.
    if (this.chunks.length) {
      gl.useProgram(this.mapProg);
      bindShared(this.mapU);
      gl.activeTexture(gl.TEXTURE3); gl.bindTexture(gl.TEXTURE_2D, this.animTex); gl.uniform1i(this.mapU.u_anim, 3);
      gl.uniform1ui(this.mapU.u_tileBase, s.tilePaletteBase);
      gl.bindVertexArray(this.mapVao);
      const planes = frustumPlanes(vpm);
      let runFirst = -1, runEnd = -1;
      const flush = () => {
        if (runFirst < 0 || runEnd <= runFirst) return;
        gl.drawArrays(gl.TRIANGLES, runFirst, runEnd - runFirst);
        stats.drawCalls++;
        stats.triangles += (runEnd - runFirst) / 3;
      };
      for (const c of this.chunks) {
        if (c.count === 0) continue;
        if (!boxVisible(planes, c.min, c.max)) continue;
        stats.chunksDrawn++;
        if (c.first === runEnd) {
          runEnd = c.first + c.count;
        } else {
          flush();
          runFirst = c.first;
          runEnd = c.first + c.count;
        }
      }
      flush();
      if (this.extraCount > 0) {
        gl.bindVertexArray(this.extraVao);
        gl.drawArrays(gl.TRIANGLES, 0, this.extraCount);
        stats.drawCalls++;
        stats.triangles += this.extraCount / 3;
      }
    }

    // Sprites: one instanced call.
    if (instances && count > 0) {
      gl.useProgram(this.spriteProg);
      bindShared(this.spriteU);
      gl.activeTexture(gl.TEXTURE3); gl.bindTexture(gl.TEXTURE_2D, this.spriteTex); gl.uniform1i(this.spriteU.u_sprites, 3);
      gl.uniform1ui(this.spriteU.u_spriteBase, s.spritePaletteBase);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.instanceVbo);
      const bytes = instances.subarray(0, count * INSTANCE_BYTES);
      if (count > this.instanceCapacity) {
        this.instanceCapacity = Math.max(count, this.instanceCapacity * 2, 256);
        gl.bufferData(gl.ARRAY_BUFFER, this.instanceCapacity * INSTANCE_BYTES, gl.DYNAMIC_DRAW);
      }
      gl.bufferSubData(gl.ARRAY_BUFFER, 0, bytes);
      gl.bindVertexArray(this.spriteVao);
      gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, count);
      stats.drawCalls++;
      stats.sprites = count;
    }
    gl.bindVertexArray(null);
    this.lastStats = stats;
    return stats;
  }
}
