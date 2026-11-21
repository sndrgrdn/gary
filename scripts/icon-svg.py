import math, random, sys

random.seed(7)

def cubic(p0, p1, p2, p3, t):
    u = 1 - t
    return tuple(u**3*a + 3*u*u*t*b + 3*u*t*t*c + t**3*d for a, b, c, d in zip(p0, p1, p2, p3))

def sample(segments, start, step=10):
    pts = [start]
    cur = start
    for seg in segments:
        if len(seg) == 1:
            p = seg[0]
            n = max(2, int(math.dist(cur, p) / step))
            pts += [(cur[0] + (p[0]-cur[0])*i/n, cur[1] + (p[1]-cur[1])*i/n) for i in range(1, n+1)]
            cur = p
        else:
            c1, c2, p = seg
            n = max(4, int((math.dist(cur, c1) + math.dist(c1, c2) + math.dist(c2, p)) / step))
            pts += [cubic(cur, c1, c2, p, i/n) for i in range(1, n+1)]
            cur = p
    return pts

def wobble(pts, amp=2.2, freq=0.045):
    ph1, ph2 = random.random()*6, random.random()*6
    out, s = [], 0
    for i, (x, y) in enumerate(pts):
        if i:
            s += math.dist(pts[i-1], pts[i])
        out.append((x + amp*math.sin(s*freq + ph1), y + amp*math.cos(s*freq*1.3 + ph2)))
    return out

def lid(cx, cy, r, left_deg, right_deg, n=40):
    a0, a1 = math.pi + math.radians(left_deg), 2*math.pi - math.radians(right_deg)
    return [(cx + r*math.cos(a0 + (a1-a0)*i/n), cy + r*math.sin(a0 + (a1-a0)*i/n)) for i in range(n+1)]

def d(pts, close=False):
    return "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in pts) + (" Z" if close else "")

def circle(cx, cy, r, n=None):
    n = n or max(24, int(r))
    return [(cx + r*math.cos(2*math.pi*i/n), cy + r*math.sin(2*math.pi*i/n)) for i in range(n)]

def spiral(cx, cy, r_end, turns, theta_end, r_start, n=200):
    total = turns*2*math.pi
    b = math.log(r_end/r_start)/total
    return [(cx + r_start*math.exp(b*total*i/n)*math.cos(theta_end-total+total*i/n),
             cy + r_start*math.exp(b*total*i/n)*math.sin(theta_end-total+total*i/n)) for i in range(n+1)]

def tapered(p0, c, p1, w0, w1, n=24):
    def q(t):
        u = 1-t
        return (u*u*p0[0]+2*u*t*c[0]+t*t*p1[0], u*u*p0[1]+2*u*t*c[1]+t*t*p1[1])
    left, right = [], []
    for i in range(n+1):
        t = i/n
        a, b = q(max(t-.01, 0)), q(min(t+.01, 1))
        l = math.dist(a, b)
        nx, ny = -(b[1]-a[1])/l, (b[0]-a[0])/l
        x, y = q(t)
        w = (w0 + (w1-w0)*t)/2
        left.append((x+nx*w, y+ny*w)); right.append((x-nx*w, y-ny*w))
    return left + right[::-1]

INK = "#1d1a22"
SX, SY, SR = 458, 488, 222

body = wobble(amp=1.4, pts=sample([
    ((236, 742), (296, 712), (380, 696)), ((560, 600),),
    ((620, 590), (628, 540), (690, 482)), ((750, 428), (848, 452), (854, 556)),
    ((858, 640), (848, 712), (828, 742)), ((820, 752), (810, 757), (796, 757)),
    ((176, 756),)], (176, 756)))
shell = wobble(circle(SX, SY, SR, 160), 2.5)
whorl = wobble(spiral(SX + 18, SY + 6, SR - 6, 1.9, math.radians(55), 26), 1.6)
back_stalk = wobble(tapered((706, 520), (680, 400), (648, 340), 40, 24), 1.2)
front_stalk = wobble(tapered((754, 520), (752, 400), (774, 326), 44, 26), 1.2)
back_eye = wobble(circle(646, 316, 42), 1.2)
front_eye = wobble(circle(778, 300, 46), 1.2)

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#ffffff"/>
    <stop offset="1" stop-color="#e4e4ea"/>
  </linearGradient>
  <radialGradient id="ground" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="#1d1a22" stop-opacity="0.22"/>
    <stop offset="1" stop-color="#1d1a22" stop-opacity="0"/>
  </radialGradient>
  <clipPath id="shellClip"><path d="{d(shell, True)}"/></clipPath>
  <clipPath id="bodyClip"><path d="{d(body, True)}"/></clipPath>
</defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>
<ellipse cx="520" cy="770" rx="340" ry="24" fill="url(#ground)"/>

<path d="{d(back_stalk, True)}" fill="#6fcdc6" stroke="{INK}" stroke-width="16" stroke-linejoin="round"/>
<path d="{d(back_eye, True)}" fill="#ffffff" stroke="{INK}" stroke-width="16" stroke-linejoin="round"/>
<circle cx="640" cy="334" r="17" fill="{INK}"/>
<circle cx="645" cy="329" r="5" fill="#ffffff"/>
<path d="{d(lid(646, 316, 42, 8, -14), True)}" fill="#6fcdc6" stroke="{INK}" stroke-width="13" stroke-linejoin="round"/>

<path d="{d(front_stalk, True)}" fill="#a8eee6" stroke="{INK}" stroke-width="16" stroke-linejoin="round"/>
<path d="{d(body, True)}" fill="#a8eee6"/>
<g clip-path="url(#bodyClip)">
  <path d="{d(wobble(sample([((300, 736), (600, 732), (840, 736)), ((840, 790),), ((170, 790),)], (170, 750)), 1.5), True)}" fill="#6fcdc6"/>
  <path d="M 712 500 C 742 474, 790 470, 816 492" fill="none" stroke="#ffffff" stroke-width="12" stroke-linecap="round" stroke-opacity="0.9"/>
</g>
<path d="{d(body, True)}" fill="none" stroke="{INK}" stroke-width="18" stroke-linejoin="round"/>

<path d="{d(front_eye, True)}" fill="#ffffff" stroke="{INK}" stroke-width="16" stroke-linejoin="round"/>
<circle cx="768" cy="318" r="19" fill="{INK}"/>
<circle cx="774" cy="312" r="6" fill="#ffffff"/>
<path d="{d(lid(778, 300, 46, -12, 10), True)}" fill="#a8eee6" stroke="{INK}" stroke-width="13" stroke-linejoin="round"/>

<path d="M 796 606 C 814 616, 834 610, 850 584" fill="none" stroke="{INK}" stroke-width="12" stroke-linecap="round"/>
<ellipse cx="786" cy="636" rx="24" ry="14" fill="#ff8fb0" fill-opacity="0.8"/>

<path d="{d(shell, True)}" fill="#ff86a8"/>
<g clip-path="url(#shellClip)">
  <path d="{d(wobble(circle(SX + 40, SY + 52, SR + 6, 160), 2), True)}" fill="none" stroke="#e85487" stroke-width="70"/>
  <path d="{d(whorl)}" fill="none" stroke="#e85487" stroke-width="30" stroke-linecap="round" transform="translate(8 10)"/>
  <path d="M 300 420 C 316 370, 350 330, 400 306" fill="none" stroke="#ffffff" stroke-width="18" stroke-linecap="round" stroke-opacity="0.85"/>
  <path d="M 290 478 L 291 470" fill="none" stroke="#ffffff" stroke-width="18" stroke-linecap="round" stroke-opacity="0.85"/>
</g>
<path d="{d(whorl)}" fill="none" stroke="{INK}" stroke-width="16" stroke-linecap="round" stroke-linejoin="round"/>
<path d="{d(shell, True)}" fill="none" stroke="{INK}" stroke-width="18" stroke-linejoin="round"/>
</svg>
'''
open(sys.argv[1] if len(sys.argv) > 1 else "Resources/Gary.svg", "w").write(svg)
