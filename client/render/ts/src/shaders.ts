// GLSL ES 3.00 shaders. Map and sprites share the palette path:
// index texture (R8UI array: TILE pages, then SPRG pages) -> virtual
// palette -> PALX -> physical palette (PPAL, stored B,G,R,_).

const common = `
uniform highp usampler2DArray u_idx;
uniform highp usampler2D u_palx;
uniform highp sampler2D u_ppal;
uniform float u_ambient;
uniform float u_lightGain;

uint physPalette(uint virt) {
  return texelFetch(u_palx, ivec2(int(virt % 128u), int(virt / 128u)), 0).r;
}
vec3 paletteColour(uint phys, uint idx) {
  return texelFetch(u_ppal, ivec2(int(phys % 64u), int((phys / 64u) * 256u + idx)), 0).bgr;
}
`;

export const mapVS = `#version 300 es
in vec3 a_pos;
in vec2 a_uv;
in uint a_tile;
in uvec2 a_fs;
in vec3 a_light;
uniform mat4 u_vp;
out vec2 v_uv;
flat out uint v_tile;
flat out uint v_flags;
out float v_shade;
out vec3 v_light;
void main() {
  // Mesh units are 64 per block. Sim axes (x east, y south, z up) to GL
  // (x right, y up, z toward the viewer from the north).
  vec3 p = a_pos / 64.0;
  gl_Position = u_vp * vec4(p.x, p.z, p.y, 1.0);
  v_uv = a_uv;
  v_tile = a_tile;
  v_flags = a_fs.x;
  v_shade = float(a_fs.y) / 255.0;
  v_light = a_light;
}`;

export const mapFS = `#version 300 es
precision highp float;
precision highp int;
${common}
uniform highp usampler2D u_anim;
uniform uint u_tileBase;
in vec2 v_uv;
flat in uint v_tile;
flat in uint v_flags;
in float v_shade;
in vec3 v_light;
out vec4 o;
void main() {
  uint tile = texelFetch(u_anim, ivec2(int(v_tile), 0), 0).r;
  uint rel = tile % 16u;
  ivec2 base = ivec2(int(rel % 4u), int(rel / 4u)) * 64;
  ivec2 p = clamp(ivec2(floor(v_uv)), ivec2(0), ivec2(63));
  uint idx = texelFetch(u_idx, ivec3(base + p, int(tile / 16u)), 0).r;
  // GTA2 transparency is binary: palette index 0 on a flat face is a hole.
  if ((v_flags & 1u) != 0u && idx == 0u) discard;
  // One-sided halves of a flat side face whose reverse shows another tile.
  if ((v_flags & 4u) != 0u && !gl_FrontFacing) discard;
  vec3 c = paletteColour(physPalette(u_tileBase + tile), idx);
  o = vec4(c * (u_ambient * v_shade + u_lightGain * v_light), 1.0);
}`;

export const spriteVS = `#version 300 es
precision highp float;
precision highp int;
in vec2 a_corner;
in vec4 i_pose;     // x, y, z (blocks, sim axes), angle (radians)
in uvec4 i_look;    // sprite, palette, kind | flags << 8, pad
uniform mat4 u_vp;
uniform highp usampler2D u_sprites;
uniform uint u_spriteBase;
out vec2 v_uv;
flat out uint v_layer;
flat out uint v_virt;
void main() {
  uint sprite = i_look.x;
  uvec4 r = texelFetch(u_sprites, ivec2(int(sprite % 64u), int(sprite / 64u)), 0);
  vec2 size = vec2(float(r.w & 255u), float(r.w >> 8u));
  // Sprites face up (-y) in the image; the sim's heading 0 is +x.
  float a = i_pose.w;
  vec2 right = vec2(-sin(a), cos(a));
  vec2 down = vec2(-cos(a), -sin(a));
  vec2 local = a_corner * size / 64.0;
  vec2 xy = i_pose.xy + right * local.x + down * local.y;
  // Lift sprites off the surface; cars above peds above items.
  uint kind = i_look.z & 255u;
  float lift = 0.02 + (kind == 0u ? 0.03 : kind == 1u ? 0.02 : 0.01);
  gl_Position = u_vp * vec4(xy.x, i_pose.z + lift, xy.y, 1.0);
  v_uv = vec2(r.xy) + (a_corner + 0.5) * size;
  v_layer = r.z;
  v_virt = i_look.y == 65535u ? u_spriteBase + sprite : i_look.y;
}`;

export const spriteFS = `#version 300 es
precision highp float;
precision highp int;
${common}
in vec2 v_uv;
flat in uint v_layer;
flat in uint v_virt;
out vec4 o;
void main() {
  ivec2 p = ivec2(floor(v_uv));
  uint idx = texelFetch(u_idx, ivec3(p, int(v_layer)), 0).r;
  if (idx == 0u) discard;
  vec3 c = paletteColour(physPalette(v_virt), idx);
  o = vec4(c * u_ambient, 1.0);
}`;
