"""Checks the S1 rendering conventions against real GTA2 maps.

    python3 -I spikes/s1/tools/check_conventions.py /path/to/GTA2/data

Reads wil/ste/bil .gmp and .sty from that folder (never copy them into the
repo). Independent of formats/ on purpose: a second reading of the DMA
layouts, in numpy. Prints one line per check; see spikes/s1/RESULT.md.
"""
import struct, sys, collections
import numpy as np


def chunks(b):
    off, out = 6, {}
    while off + 8 <= len(b):
        tag = b[off:off + 4].decode('latin1')
        n = struct.unpack_from('<I', b, off + 4)[0]
        out[tag] = b[off + 8:off + 8 + n]
        off += 8 + n
    return out


def load_gmp(path):
    d = chunks(open(path, 'rb').read())['DMAP']
    base = np.frombuffer(d, '<u4', 65536).reshape(256, 256)
    o = 65536 * 4
    ncw = struct.unpack_from('<I', d, o)[0]; o += 4
    cols = np.frombuffer(d, '<u4', ncw, o); o += ncw * 4
    nb = struct.unpack_from('<I', d, o)[0]; o += 4
    blk = np.frombuffer(d, np.uint8, nb * 12, o).reshape(nb, 12)
    faces = blk[:, :10].copy().view('<u2').reshape(nb, 5)  # left right top bottom lid
    cells = np.zeros((8, 256, 256), np.int64)
    cb = cols.view(np.uint8)
    for y in range(256):
        for x in range(256):
            s = int(base[y, x]); h = int(cb[s * 4]); of = int(cb[s * 4 + 1])
            cells[of:h, y, x] = cols[s + 1:s + 1 + h - of]
    return cells, faces, blk[:, 11].copy()


def load_sty(path):
    c = chunks(open(path, 'rb').read())
    t = np.frombuffer(c['TILE'], np.uint8).reshape(-1, 4, 64, 4, 64).transpose(0, 1, 3, 2, 4).reshape(-1, 64, 64)
    palx = np.frombuffer(c['PALX'], '<u2')
    ppal = np.frombuffer(c['PPAL'], np.uint8).reshape(-1, 256, 64, 4)
    rgb = np.stack([ppal[palx[i] // 64, :, palx[i] % 64, :3][:, ::-1][t[i]] for i in range(len(t))])
    return t, rgb.astype(np.int32)


def orient(img, flip, rot):
    """The mesh's convention (mesh.zig `orient`): rotate clockwise, then mirror."""
    a = np.rot90(img, -rot)
    return a[:, ::-1] if flip else a


def orient_alt(img, flip, rot):
    """The alternative: mirror first, then rotate clockwise."""
    return np.rot90(img[:, ::-1] if flip else img, -rot)


def main(data):
    for n in ['wil', 'ste', 'bil']:
        cells, F, st = load_gmp(f'{data}/{n}.gmp')
        idx, rgb = load_sty(f'{data}/{n}.sty')
        code = (st >> 2)[cells]
        solid = ((F != 0).any(1) | (st != 0))[cells]
        lid = F[:, 4][cells]
        print(n)

        # 1. Ramp direction: the end named by the direction is the high end.
        D = {0: (0, -1), 1: (0, 1), 2: (-1, 0), 3: (1, 0)}  # up down left right
        ok = bad = 0
        for d, (dx, dy) in D.items():
            top = 9 + d * 8 + 7  # 7-degree group, highest piece
            for z, y, x in zip(*np.nonzero(code == top)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < 256 and 0 <= ny < 256:
                    if solid[z, ny, nx] and code[z, ny, nx] == 0: ok += 1
                    else: bad += 1
        print(f'  ramps: top of a 7-degree ramp meets a full block ahead {ok}, not {bad}')

        # 2. Lid orientation: pixel continuity across neighbouring flat lids.
        top = np.full((256, 256), -1)
        for z in range(8):
            t = lid[z] & 1023
            good = solid[z] & (code[z] == 0) & (t > 0) & (t < 992) & ((lid[z] & 0x1000) == 0)
            above = solid[z + 1] if z < 7 else np.zeros((256, 256), bool)
            top = np.where(good & ~above, z, np.where(solid[z], -1, top))
        err = collections.Counter(); pairs = 0
        for y in range(255):
            for x in range(255):
                z = top[y, x]
                if z < 0: continue
                for dx, dy in [(1, 0), (0, 1)]:
                    if top[y + dy, x + dx] != z: continue
                    a, b = int(lid[z, y, x]), int(lid[z, y + dy, x + dx])
                    if not (((a >> 13) & 1 and (a >> 14) % 2) or ((b >> 13) & 1 and (b >> 14) % 2)): continue
                    pairs += 1
                    for name, f in [('mesh', orient), ('alt', orient_alt)]:
                        A = f(rgb[a & 1023], (a >> 13) & 1, a >> 14); B = f(rgb[b & 1023], (b >> 13) & 1, b >> 14)
                        err[name] += (np.abs(A[:, -1] - B[:, 0]) if dx else np.abs(A[-1] - B[0])).mean()
        print(f'  lids: {pairs} neighbour pairs with a flipped and quarter-turned lid; mean edge colour step: '
              f'mesh convention {err["mesh"] / pairs:.1f}, flip-before-rotate {err["alt"] / pairs:.1f} (lower is better)')

        # 3. Flat side faces: a non-flat see-through face sits opposite a flat one.
        zero = (idx == 0).mean((1, 2))
        used = np.zeros(len(F), bool); used[np.unique(cells)] = True
        t = F & 1023; fl = (F >> 12) & 1
        tot = opp = 0
        for i, o in [(0, 1), (1, 0), (2, 3), (3, 2)]:
            see = used & (t[:, i] > 0) & (t[:, i] < 992) & (fl[:, i] == 0) & (zero[np.minimum(t[:, i], 991)] > 0.3)
            tot += see.sum(); opp += (see & (fl[:, o] == 1) & (t[:, o] > 0)).sum()
        print(f'  flat sides: {opp} of {tot} non-flat faces with see-through tiles are opposite a flat face')

        # 4. Diagonals: only the left face is set on left-facing pieces, the right on right-facing.
        for k in [45, 46, 47, 48, 49, 50, 51, 52]:
            sel = np.unique(cells[code == k])
            has = (t[sel, :4] > 0).mean(0)
            print(f'  code {k}: share with left/right/top/bottom set ' + ' '.join(f'{v:.2f}' for v in has)
                  + f', lid 1023 {(t[sel, 4] == 1023).mean():.2f}')

        # 5. Partial blocks: opaque pixels of see-through lids sit in the 24 px strip.
        for k, axis in [(53, 0), (55, 1)]:
            acc = np.zeros((64, 64)); m = 0
            for v in lid[code == k]:
                v = int(v)
                if (v & 1023) and (v & 1023) < 992 and (v >> 12) & 1 and not (v >> 13):
                    acc += idx[v & 1023] != 0; m += 1
            if m:
                prof = acc.mean(axis) / m
                nz = np.nonzero(prof > 0.5)[0]
                print(f'  code {k}: {m} see-through lids, opaque {"x" if axis == 0 else "y"} range '
                      f'{(nz.min(), nz.max() + 1) if len(nz) else None}')


if __name__ == '__main__':
    main(sys.argv[1])
