#!/usr/bin/env python3
"""Generate exploded axonometric paths for the homelab stack."""
import math

def iso(x, y, z, ox, oy):
    return ox + x - y, oy + (x + y) / 2 - z

def fmt(n):
    if isinstance(n, str):
        return n
    s = f"{n:.2f}"
    if '.' in s:
        s = s.rstrip('0').rstrip('.')
    return s

def pt_str(p):
    return f"{fmt(p[0])} {fmt(p[1])}"

def main():
    viewbox_w = 1000
    viewbox_h = 620
    ox = 360
    oy = 432
    
    w, d = 160, 160
    r = 10
    arc_rx = r * math.sqrt(2)
    arc_ry = r / math.sqrt(2)
    
    parts = [
        {'name': 'Bare Metal', 'sub': 'Raspberry Pi · x86 Host', 't': 20, 'level': 0},
        {'name': 'Hypervisor', 'sub': 'Proxmox VE · KVM · LXC', 't': 16, 'level': 1},
        {'name': 'Virtual Machines', 'sub': 'Sachiel · Shamshel · Ramiel · Gaghiel · Sahaquiel · Ireul', 't': 16, 'level': 2, 'focal': True},
        {'name': 'Docker Runtime', 'sub': 'Docker Engine per VM', 't': 16, 'level': 3},
        {'name': 'Applications', 'sub': 'Plex · Traefik · Dozzle · Sonarr · Homepage', 't': 16, 'level': 4},
    ]
    
    max_t = max(p['t'] for p in parts)
    top_face_h = (w + d) / 2
    k = 0.45
    gap = max(k * top_face_h, 3 * max_t)
    gap = math.ceil(gap / 4) * 4
    
    z = 0
    for p in parts:
        p['z_bottom'] = z
        z += p['t'] + gap
    
    paper = "#f5f5f5"
    ink = "#2d3142"
    muted = "#4f5d75"
    accent = "#bf4520"
    
    def arc(start, end, sweep=1):
        return f"A {fmt(arc_rx)} {fmt(arc_ry)} 0 0 {sweep} {pt_str(end)}"
    
    def make_part(z_bottom, thickness, is_focal, name, sub, level):
        z_top = z_bottom + thickness
        
        # Extreme points
        top    = iso(0, 0, z_top, ox, oy)
        left   = iso(0, d, z_top, ox, oy)
        bottom = iso(w, d, z_top, ox, oy)
        right  = iso(w, 0, z_top, ox, oy)
        
        bot_top    = iso(0, 0, z_bottom, ox, oy)
        bot_left   = iso(0, d, z_bottom, ox, oy)
        bot_bottom = iso(w, d, z_bottom, ox, oy)
        bot_right  = iso(w, 0, z_bottom, ox, oy)
        
        # --- Silhouette outer arc endpoints (from reference example pattern) ---
        tl_a1 = (left[0] + r*0.586, left[1] - r*0.5)
        tl_a2 = (left[0] + r, left[1] - r)
        t_a1  = (top[0] - r, top[1] + r*0.5)
        t_a2  = (top[0] + r, top[1] + r*0.5)
        tr_a1 = (right[0] - r, right[1] - r)
        tr_a2 = (right[0] - r*0.586, right[1] - r*0.5)
        
        br_a1 = (bot_right[0] - r*0.586, bot_right[1])
        br_a2 = (bot_right[0] - r, bot_right[1] + r*0.5)
        b_a1  = (bot_bottom[0] + r, bot_bottom[1] - r*0.5)
        b_a2  = (bot_bottom[0] - r, bot_bottom[1] - r*0.5)
        bl_a1 = (bot_left[0] + r, bot_left[1] + r*0.5)
        bl_a2 = (bot_left[0] + r*0.586, bot_left[1])
        
        # --- Silhouette: full outer perimeter ---
        sil = f"M {pt_str(tl_a1)} {arc(tl_a1, tl_a2)} L {pt_str(t_a1)} {arc(t_a1, t_a2)} L {pt_str(tr_a1)} {arc(tr_a1, tr_a2)}"
        sil += f" L {pt_str(br_a1)} {arc(br_a1, br_a2, sweep=0)} L {pt_str(b_a1)} {arc(b_a1, b_a2, sweep=0)} L {pt_str(bl_a1)} {arc(bl_a1, bl_a2, sweep=0)} Z"
        
        # --- Top face inner rounded rectangle (fill) ---
        # Corner arc endpoints (projected model rounded-rect arc endpoints)
        bl_corner_a1 = iso(r, d, z_top, ox, oy)      # bottom-left arc start
        bl_corner_a2 = iso(0, d - r, z_top, ox, oy)  # bottom-left arc end
        tl_corner_a1 = iso(0, r, z_top, ox, oy)       # top-left arc start
        tl_corner_a2 = iso(r, 0, z_top, ox, oy)       # top-left arc end
        tr_corner_a1 = iso(w - r, 0, z_top, ox, oy)   # top-right arc start
        tr_corner_a2 = iso(w, r, z_top, ox, oy)        # top-right arc end
        br_corner_a1 = iso(w, d - r, z_top, ox, oy)    # bottom-right arc start
        br_corner_a2 = iso(w - r, d, z_top, ox, oy)   # bottom-right arc end
        
        # Straight edges between arcs
        left_edge_top    = iso(0, r, z_top, ox, oy)
        left_edge_bottom = iso(0, d - r, z_top, ox, oy)
        top_edge_left    = iso(r, 0, z_top, ox, oy)
        top_edge_right   = iso(w - r, 0, z_top, ox, oy)
        right_edge_top   = iso(w, r, z_top, ox, oy)
        right_edge_bottom = iso(w, d - r, z_top, ox, oy)
        bottom_edge_right = iso(w - r, d, z_top, ox, oy)
        bottom_edge_left  = iso(r, d, z_top, ox, oy)
        
        # Fill traces: bottom-left arc → left edge → top-left arc → top edge → top-right arc → right edge → bottom-right arc → bottom edge → close
        top_fill = f"M {pt_str(bl_corner_a1)} {arc(bl_corner_a1, bl_corner_a2)}"
        top_fill += f" L {pt_str(left_edge_top)} {arc(left_edge_top, tl_corner_a2)}"
        top_fill += f" L {pt_str(top_edge_right)} {arc(top_edge_right, tr_corner_a2)}"
        top_fill += f" L {pt_str(right_edge_bottom)} {arc(right_edge_bottom, br_corner_a2)}"
        top_fill += f" L {pt_str(bottom_edge_left)} {arc(bottom_edge_left, bl_corner_a1)} Z"
        
        # Wait, the arcs need to go in the right order. Let me trace carefully:
        # Start at bottom-left corner: arc from (r, d) to (0, d-r)
        # Then left edge: from (0, d-r) to (0, r)
        # Then top-left arc: from (0, r) to (r, 0)
        # Then top edge: from (r, 0) to (w-r, 0)
        # Then top-right arc: from (w-r, 0) to (w, r)
        # Then right edge: from (w, r) to (w, d-r)
        # Then bottom-right arc: from (w, d-r) to (w-r, d)
        # Then bottom edge: from (w-r, d) to (r, d)
        # Close to start.
        
        # Actually the arc commands I wrote connect the wrong pairs. Let me rewrite.
        top_fill = f"M {pt_str(bl_corner_a1)} {arc(bl_corner_a1, bl_corner_a2)}"
        top_fill += f" L {pt_str(left_edge_top)} {arc(left_edge_top, tl_corner_a2)}"
        top_fill += f" L {pt_str(top_edge_right)} {arc(top_edge_right, tr_corner_a2)}"
        top_fill += f" L {pt_str(right_edge_bottom)} {arc(right_edge_bottom, br_corner_a2)}"
        top_fill += f" L {pt_str(bottom_edge_left)} Z"
        
        # Hmm wait, the arc from bottom_edge_left to bl_corner_a1 is the same corner arc we started with.
        # So we don't need an arc there, just Z close.
        # Let me simplify:
        top_fill = f"M {pt_str(bl_corner_a1)} {arc(bl_corner_a1, bl_corner_a2)}"
        top_fill += f" L {pt_str(left_edge_top)} {arc(left_edge_top, tl_corner_a2)}"
        top_fill += f" L {pt_str(top_edge_right)} {arc(top_edge_right, tr_corner_a2)}"
        top_fill += f" L {pt_str(right_edge_bottom)} {arc(right_edge_bottom, br_corner_a2)}"
        top_fill += f" L {pt_str(bottom_edge_left)} Z"
        
        # --- Side faces ---
        # Left face: quadrilateral connecting left edges of top and bottom faces
        bot_left_edge_top    = iso(0, r, z_bottom, ox, oy)
        bot_left_edge_bottom = iso(0, d - r, z_bottom, ox, oy)
        left_face = f"M {pt_str(left_edge_top)} L {pt_str(left_edge_bottom)} L {pt_str(bot_left_edge_bottom)} L {pt_str(bot_left_edge_top)} Z"
        
        # Right face
        bot_right_edge_top    = iso(w, r, z_bottom, ox, oy)
        bot_right_edge_bottom = iso(w, d - r, z_bottom, ox, oy)
        right_face = f"M {pt_str(right_edge_top)} L {pt_str(right_edge_bottom)} L {pt_str(bot_right_edge_bottom)} L {pt_str(bot_right_edge_top)} Z"
        
        # --- Top face detail line (rim) ---
        # Traces the visible top face edges + arcs
        top_detail = f"M {pt_str(left_edge_top)} {arc(left_edge_top, tl_corner_a2)} L {pt_str(top_edge_right)} {arc(top_edge_right, tr_corner_a2)} L {pt_str(right_edge_bottom)} {arc(right_edge_bottom, br_corner_a2)}"
        
        # --- Label ---
        label_x = right[0] + 60
        label_y = (iso(w, r, z_top, ox, oy)[1] + iso(w, r, z_bottom, ox, oy)[1]) / 2
        leader_start = (right[0] + 8, label_y)
        leader_end = (label_x - 12, label_y)
        
        return {
            'silhouette': sil,
            'top_fill': top_fill,
            'left_face': left_face,
            'right_face': right_face,
            'top_detail': top_detail,
            'label_x': label_x, 'label_y': label_y,
            'leader_start': leader_start, 'leader_end': leader_end,
            'name': name, 'sub': sub, 'is_focal': is_focal,
            'z_bottom': z_bottom, 'thickness': thickness, 'level': level,
        }
    
    generated = []
    for p in parts:
        g = make_part(p['z_bottom'], p['t'], p.get('focal', False), p['name'], p['sub'], p['level'])
        generated.append(g)
    
    # Trace lines
    bottom = generated[0]
    top = generated[-1]
    trace_left_start = iso(0, d, bottom['z_bottom'] + bottom['thickness'], ox, oy)
    trace_left_end   = iso(0, d, top['z_bottom'] + top['thickness'], ox, oy)
    trace_right_start = iso(w, 0, bottom['z_bottom'] + bottom['thickness'], ox, oy)
    trace_right_end   = iso(w, 0, top['z_bottom'] + top['thickness'], ox, oy)
    
    svg_content = []
    svg_content.append(f'  <line data-role="trace" x1="{fmt(trace_left_start[0])}" y1="{fmt(trace_left_start[1])}" x2="{fmt(trace_left_end[0])}" y2="{fmt(trace_left_end[1])}" stroke="rgba(45,49,66,0.30)" stroke-width="0.8" stroke-dasharray="4,3"/>')
    svg_content.append(f'  <line data-role="trace" x1="{fmt(trace_right_start[0])}" y1="{fmt(trace_right_start[1])}" x2="{fmt(trace_right_end[0])}" y2="{fmt(trace_right_end[1])}" stroke="rgba(45,49,66,0.30)" stroke-width="0.8" stroke-dasharray="4,3"/>')
    
    for g in generated:
        if g['is_focal']:
            top_fill_c = "rgba(191,69,32,0.10)"
            left_fill_c = "rgba(191,69,32,0.20)"
            right_fill_c = "rgba(191,69,32,0.32)"
            stroke_c = accent
            detail_c = "rgba(191,69,32,0.70)"
            label_dot_c = accent
            label_sub_c = accent
            label_leader_c = "rgba(191,69,32,0.60)"
        else:
            top_fill_c = "#ffffff"
            left_fill_c = "rgba(45,49,66,0.07)"
            right_fill_c = "rgba(45,49,66,0.15)"
            stroke_c = ink
            detail_c = "rgba(45,49,66,0.55)"
            label_dot_c = ink
            label_sub_c = muted
            label_leader_c = "rgba(45,49,66,0.40)"
        
        part_id = f"part-{g['level']}"
        svg_content.append(f'  <g data-part="{part_id}" data-name="{g["name"]}" data-focal="{str(g["is_focal"]).lower()}">')
        svg_content.append(f'    <path d="{g["top_fill"]}" fill="{top_fill_c}"/>')
        svg_content.append(f'    <path d="{g["left_face"]}" fill="{left_fill_c}"/>')
        svg_content.append(f'    <path d="{g["right_face"]}" fill="{right_fill_c}"/>')
        svg_content.append(f'    <path d="{g["top_detail"]}" fill="none" stroke="{detail_c}" stroke-width="0.8"/>')
        svg_content.append(f'    <path data-role="silhouette" d="{g["silhouette"]}" fill="none" stroke="{stroke_c}" stroke-width="1.2" stroke-linejoin="round"/>')
        svg_content.append(f'    <g data-role="label">')
        svg_content.append(f'      <line data-role="leader" x1="{fmt(g["leader_start"][0])}" y1="{fmt(g["leader_start"][1])}" x2="{fmt(g["leader_end"][0])}" y2="{fmt(g["leader_end"][1])}" stroke="{label_leader_c}" stroke-width="0.8"/>')
        svg_content.append(f'      <circle cx="{fmt(g["leader_start"][0] - 6)}" cy="{fmt(g["leader_start"][1])}" r="2" fill="{label_dot_c}"/>')
        svg_content.append(f'      <text data-role="name" x="{fmt(g["label_x"])}" y="{fmt(g["label_y"] - 1)}" fill="{ink}" font-size="16" font-weight="600" font-family="\'Geist\', sans-serif">{g["name"]}</text>')
        svg_content.append(f'      <text x="{fmt(g["label_x"])}" y="{fmt(g["label_y"] + 15)}" fill="{label_sub_c}" font-size="10" font-family="\'Geist Mono\', monospace" letter-spacing="0.08em">{g["sub"]}</text>')
        svg_content.append(f'    </g>')
        svg_content.append(f'  </g>')
    
    svg_content.append(f'  <text x="{ox - 80}" y="{viewbox_h - 24}" fill="{muted}" font-size="8" font-family="\'Geist Mono\', monospace" letter-spacing="0.18em">FOCAL LAYER</text>')
    svg_content.append(f'  <text x="{ox + 40}" y="{viewbox_h - 24}" fill="{muted}" font-size="8.5" font-family="\'Geist\', sans-serif" font-style="italic">Virtual Machines layer is the focal point — named after Evangelion Angels, provisioned by Terraform.</text>')
    
    svg = f'''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Homelab Stack · Exploded axonometric</title>
  <link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&family=Geist:wght@400;500;600&family=Geist+Mono:wght@400;500;600&display=swap" rel="stylesheet">
  <style>
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
    :root {{
      --color-paper:   #f5f5f5;
      --color-ink:     #2d3142;
      --color-muted:   #4f5d75;
      --color-accent:  #bf4520;
      --font-sans:     'Geist', system-ui, sans-serif;
      --font-serif:    'Instrument Serif', serif;
      --font-mono:     'Geist Mono', ui-monospace, monospace;
    }}
    body {{
      font-family: var(--font-sans);
      background: var(--color-paper);
      color: var(--color-ink);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 3rem 2rem;
    }}
    .frame {{ max-width: 1200px; width: 100%; }}
    .diagram-container {{ width: 100%; overflow-x: auto; }}
    .eyebrow {{
      font-family: var(--font-mono);
      font-size: 0.66rem;
      font-weight: 500;
      letter-spacing: 0.18em;
      text-transform: uppercase;
      color: var(--color-muted);
      margin-bottom: 0.5rem;
    }}
    h1 {{
      font-family: var(--font-serif);
      font-size: clamp(1.5rem, 2.4vw + 0.75rem, 2rem);
      font-weight: 400;
      letter-spacing: -0.02em;
      line-height: 1.15;
      color: var(--color-ink);
      margin-bottom: 1.5rem;
    }}
    svg {{ width: 100%; min-width: 1000px; display: block; }}
    @media print {{
      .diagram-container {{ overflow-x: visible; }}
      svg {{ min-width: 0; }}
    }}
  </style>
</head>
<body>
  <div class="frame">
    <p class="eyebrow">Exploded axonometric · Diagram Design</p>
    <h1>Homelab Stack — From silicon to containers</h1>
    <div class="diagram-container">
      <svg viewBox="0 0 {viewbox_w} {viewbox_h}" xmlns="http://www.w3.org/2000/svg" role="img" aria-labelledby="exploded-title exploded-desc">
        <title id="exploded-title">Homelab Stack — From silicon to containers</title>
        <desc id="exploded-desc">Exploded axonometric view of the homelab stack showing five physical layers from bare metal hardware through Proxmox, VMs, Docker, and applications, with VMs as the focal layer.</desc>
        <rect width="100%" height="100%" fill="{paper}"/>
        <g data-exploded data-origin="{ox} {oy}" data-gap="{gap}">
'''
    svg += '\n'.join(svg_content)
    svg += f'''
        </g>
      </svg>
    </div>
  </div>
</body>
</html>'''
    
    with open('/home/borja/projects/homelab/doc/homelab-stack.html', 'w') as f:
        f.write(svg)
    
    print("Generated homelab-stack.html")

if __name__ == '__main__':
    main()
