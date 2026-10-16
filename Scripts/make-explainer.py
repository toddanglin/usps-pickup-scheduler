#!/usr/bin/env python3
"""Renders the README explainer video from the UI test's screenshots.

    make-explainer.py [--screens DIR] [--out DIR] [--work DIR]

Writes <out>/explainer.mp4 (1280x720, 30 fps, silent unless --narrate) and
<out>/explainer.gif (640x360, 12 fps, silent). Needs Python 3 with Pillow,
ffmpeg/ffprobe on PATH (or in /opt/homebrew/bin), and macOS `say`.

The screenshots must be clean ones, without the footer's mock-host label:

    make uitest CLEAN=1 UISCREENS=.build/explainer-screens
    make explainer

Every scene lasts max(its narration + 0.6 s, its minimum), so changing a line
of narration re-times the video on its own.
"""
import argparse
import math
import os
import shutil
import subprocess
import sys
import wave

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1280, 720
FPS = 30
DISSOLVE = 0.5          # seconds of cross-dissolve at the start of each scene
VOICE_DELAY = 0.25      # narration starts this long into its scene
VOICE_TAIL = 0.6        # scene lasts at least narration + this
SAY_VOICE, SAY_RATE = "Samantha", "185"
AUDIO_RATE = 48000

INK = (29, 29, 31)
SUB = (110, 110, 115)
ACCENT = (0, 113, 227)
BG_TOP, BG_BOTTOM = (245, 247, 251), (233, 238, 247)

MARGIN = 96              # left text margin (safe area is >= 64)
CARD_W = 320             # popover width on screen (the pickup form is then ~600 tall)
CARD_CX = 940            # popover centre x (right half)
TEXT_W = 560             # text column width; ends well left of the card

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON = os.path.join(ROOT, "Pickup/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png")


def tool(name):
    found = shutil.which(name)
    if found:
        return found
    brew = os.path.join("/opt/homebrew/bin", name)
    if os.path.exists(brew):
        return brew
    sys.exit(f"make-explainer: {name} not found")


FFMPEG, FFPROBE = tool("ffmpeg"), tool("ffprobe")

# --------------------------------------------------------------------------
# Fonts


def font(size, weight="Regular"):
    for path in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/SFNSDisplay.ttf"):
        if os.path.exists(path):
            f = ImageFont.truetype(path, size)
            try:
                f.set_variation_by_name(weight)
            except Exception:
                pass
            return f
    for path in ("/System/Library/Fonts/HelveticaNeue.ttc", "/System/Library/Fonts/Helvetica.ttc"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size, index=1 if weight in ("Semibold", "Bold") else 0)
    return ImageFont.load_default()


F_HEAD = font(44, "Semibold")
F_SUB = font(26)
F_TITLE = font(72, "Semibold")
F_SMALL = font(20)
F_URL = font(28, "Medium")

# --------------------------------------------------------------------------
# Helpers


def ease(t):
    t = min(max(t, 0.0), 1.0)
    return 0.5 - 0.5 * math.cos(math.pi * t)


def lerp(a, b, t):
    return a + (b - a) * t


def gradient():
    """Very subtle diagonal gradient, top-left to bottom-right."""
    small = Image.new("RGB", (64, 36))
    px = small.load()
    for y in range(36):
        for x in range(64):
            t = (x / 63 + y / 35) / 2
            px[x, y] = tuple(round(lerp(BG_TOP[i], BG_BOTTOM[i], t)) for i in range(3))
    return small.resize((W, H), Image.BICUBIC)


def wrap(text, f, width):
    lines, line = [], ""
    for word in text.split():
        trial = (line + " " + word).strip()
        if f.getlength(trial) <= width or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines


def text_layer(blocks, width, align="left"):
    """RGBA image of stacked text blocks: [(text, font, colour, gap_before)]."""
    rows = []
    for text, f, colour, gap in blocks:
        lines = wrap(text, f, width)
        asc, desc = f.getmetrics()
        lh = round((asc + desc) * 1.12)
        for i, ln in enumerate(lines):
            rows.append((ln, f, colour, gap if i == 0 else 0, lh))
    total = sum(r[3] + r[4] for r in rows)
    img = Image.new("RGBA", (width, total + 8), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    y = 0
    for ln, f, colour, gap, lh in rows:
        y += gap
        x = 0
        if align == "center":
            x = (width - f.getlength(ln)) / 2
        d.text((x, y), ln, font=f, fill=colour + (255,))
        y += lh
    return img


def with_alpha(img, a):
    if a >= 0.999:
        return img
    out = img.copy()
    out.putalpha(out.getchannel("A").point(lambda v: round(v * a)))
    return out


def paste_fade(frame, layer, xy, a):
    if a <= 0.001:
        return
    frame.alpha_composite(with_alpha(layer, a), (round(xy[0]), round(xy[1])))


def rounded_mask(size, radius, ss=4):
    w, h = size
    big = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, w * ss - 1, h * ss - 1), radius * ss, fill=255)
    return big.resize(size, Image.LANCZOS)


def shadow_for(size, radius, blur=22, offset=(0, 14), opacity=70):
    """A soft drop shadow, returned with the padding it needs around the card."""
    pad = blur * 3
    w, h = size
    img = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle(
        (pad + offset[0], pad + offset[1], pad + offset[0] + w, pad + offset[1] + h),
        radius, fill=(20, 30, 60, opacity))
    return img.filter(ImageFilter.GaussianBlur(blur)), pad


# --------------------------------------------------------------------------
# Popover cards


class Card:
    """A popover screenshot drawn CARD_W wide (times `scale`), with its
    rounded corners and a soft shadow, at sub-pixel positions so slow zooms
    do not jitter.

    Every popover is the same width, so scaling by width keeps them all the
    same size on screen whether the capture is 1x or 2x; shorter popovers are
    centred vertically."""

    RADIUS = 17       # the popover's own corner radius in points, plus a little to hide the edge
    PAD = 8           # transparent source border, so the resample box may overhang

    def __init__(self, path):
        src = Image.open(path).convert("RGBA")
        sw, sh = src.size
        self.k = CARD_W / sw                       # screen px per source px at scale 1
        self.size = (CARD_W, sh * self.k)
        radius = self.RADIUS * sw / 340
        src.putalpha(rounded_mask(src.size, radius))
        self.src = Image.new("RGBA", (sw + 2 * self.PAD, sh + 2 * self.PAD), (0, 0, 0, 0))
        self.src.paste(src, (self.PAD, self.PAD))
        self.sw, self.sh = sw, sh
        self.shadow, self.pad = shadow_for((CARD_W, round(self.size[1])), radius * self.k)

    def draw(self, frame, scale=1.0, centre=None, alpha=1.0):
        """Draw with the card's centre at `centre` (default: right-half centre)."""
        if alpha <= 0.001:
            return
        cx, cy = centre or (CARD_CX, H / 2)
        k = self.k * scale
        w, h = self.sw * k, self.sh * k
        fx, fy = cx - w / 2, cy - h / 2
        sh_w = round(self.shadow.size[0] * scale)
        sh_h = round(self.shadow.size[1] * scale)
        shadow = self.shadow if abs(scale - 1) < 1e-3 else self.shadow.resize((sh_w, sh_h), Image.BILINEAR)
        paste_fade(frame, shadow, (cx - sh_w / 2, cy - sh_h / 2), alpha)
        x0, y0 = math.floor(fx) - 1, math.floor(fy) - 1
        x1, y1 = math.ceil(fx + w) + 1, math.ceil(fy + h) + 1
        P = self.PAD
        box = ((x0 - fx) / k + P, (y0 - fy) / k + P, (x1 - fx) / k + P, (y1 - fy) / k + P)
        img = self.src.resize((x1 - x0, y1 - y0), Image.LANCZOS, box=box)
        paste_fade(frame, img, (x0, y0), alpha)


# --------------------------------------------------------------------------
# Scenes. Each is (min seconds, narration, render(t, duration) -> RGBA frame)


class Scenes:
    def __init__(self, screens):
        self.bg = gradient().convert("RGBA")
        self.icon = Image.open(ICON).convert("RGBA").crop((50, 50, 462, 462))
        self.screens = screens
        self.cards = {}

    def card(self, name):
        if name not in self.cards:
            path = os.path.join(self.screens, name + ".png")
            if not os.path.exists(path):
                sys.exit(f"make-explainer: missing screenshot {path}\n"
                         "Run `make uitest CLEAN=1 UISCREENS=<dir>` first.")
            self.cards[name] = Card(path)
        return self.cards[name]

    def blank(self):
        return self.bg.copy()

    # Left-column caption: fades in and slides up 20 px.
    def caption(self, frame, layer, t, delay=0.35, dur=0.7):
        p = ease((t - delay) / dur)
        y = (H - layer.size[1]) / 2 + 20 * (1 - p)
        paste_fade(frame, layer, (MARGIN, y), p)

    def card_scene(self, names, head, sub, switch_at=None, press=None):
        """One or two screenshots (dissolving at `switch_at` seconds) with a
        slow 2.5% push-in and a caption on the left. `press` = (time, box)
        softly highlights a button on the first screenshot, box given as
        fractions of the source (x0, y0, x1, y1)."""
        layer = text_layer([(head, F_HEAD, INK, 0)] + ([(sub, F_SUB, SUB, 18)] if sub else []),
                           TEXT_W)

        def render(t, dur):
            f = self.blank()
            appear = ease(t / 0.6)
            if switch_at is None or len(names) == 1:
                c = self.card(names[0])
                c.draw(f, 1.0 + 0.025 * ease(t / dur), alpha=appear)
            else:
                a, b = self.card(names[0]), self.card(names[1])
                mix = ease((t - switch_at) / DISSOLVE)
                za = 1.0 + 0.02 * ease(t / (switch_at + DISSOLVE))
                zb = 1.0 + 0.025 * ease((t - switch_at) / (dur - switch_at))
                if mix < 1:
                    a.draw(f, za, alpha=appear * (1 - mix))
                    if press:
                        self.press(f, a, za, press[1], (t - press[0]) / 0.6, appear * (1 - mix))
                if mix > 0:
                    b.draw(f, zb, alpha=mix)
            self.caption(f, layer, t)
            return f
        return render

    def press(self, frame, card, scale, box, p, alpha):
        """A brief, soft darkening of a button, as if clicked (0 <= p <= 1)."""
        if not 0 < p < 1:
            return
        k = card.k * scale
        cx, cy = CARD_CX, H / 2
        x0, y0, x1, y1 = (cx + (box[0] - 0.5) * card.sw * k, cy + (box[1] - 0.5) * card.sh * k,
                          cx + (box[2] - 0.5) * card.sw * k, cy + (box[3] - 0.5) * card.sh * k)
        a = math.sin(math.pi * p) * alpha
        ss = 3
        ov = Image.new("RGBA", (round((x1 - x0) * ss), round((y1 - y0) * ss)), (0, 0, 0, 0))
        ImageDraw.Draw(ov).rounded_rectangle((0, 0, ov.size[0] - 1, ov.size[1] - 1),
                                             (y1 - y0) / 2 * ss, fill=(0, 30, 90, round(70 * a)))
        ov = ov.resize((round(x1 - x0), round(y1 - y0)), Image.LANCZOS)
        frame.alpha_composite(ov, (round(x0), round(y0)))

    def title(self):
        icon = self.icon.resize((200, 200), Image.LANCZOS)
        shadow, pad = shadow_for((176, 176), 40, blur=18, offset=(0, 12), opacity=55)
        name = text_layer([("Pickup", F_TITLE, INK, 0)], 700, "center")
        tag = text_layer([("Schedule USPS carrier pickups from your Mac’s menu bar.",
                           F_SUB, SUB, 0)], 900, "center")

        def render(t, dur):
            f = self.blank()
            p = ease(t / 0.8)
            s = 0.94 + 0.06 * p
            ic = icon.resize((round(200 * s), round(200 * s)), Image.LANCZOS)
            cx, top = W / 2, 150
            paste_fade(f, shadow, (cx - shadow.size[0] / 2, top + 12 - pad + 12), p)
            paste_fade(f, ic, (cx - ic.size[0] / 2, top + (200 - ic.size[1]) / 2), p)
            q = ease((t - 0.35) / 0.7)
            paste_fade(f, name, (cx - 350, 385 + 20 * (1 - q)), q)
            r = ease((t - 0.7) / 0.7)
            paste_fade(f, tag, (cx - 450, 480 + 20 * (1 - r)), r)
            return f
        return render

    def problem(self):
        layer = text_layer([
            ("usps.com makes you sign in and re-enter your address.", F_HEAD, INK, 0),
            ("Every. Time.", F_HEAD, (196, 43, 28), 14),
        ], TEXT_W)
        glyph, spinner_pos = self._browser_glyph()
        spokes = self._spinner_frames(48)

        def render(t, dur):
            f = self.blank()
            p = ease(t / 0.6)
            gx = round(CARD_CX - glyph.size[0] / 2)
            gy = round((H - glyph.size[1]) / 2)
            g = glyph.copy()
            sp = spokes[int(t * 12) % len(spokes)]
            g.alpha_composite(sp, (spinner_pos[0] - sp.size[0] // 2, spinner_pos[1] - sp.size[1] // 2))
            paste_fade(f, g, (gx, gy + 12 * (1 - p)), p)
            self.caption(f, layer, t)
            return f
        return render

    def _browser_glyph(self):
        """A generic browser window with a sign-in form, drawn at 3x."""
        ss = 3
        gw, gh = 470, 420
        shadow, pad = shadow_for((gw, gh), 16)
        img = Image.new("RGBA", ((gw + pad * 2) * ss, (gh + pad * 2) * ss), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)

        def R(x0, y0, x1, y1):
            return [(pad + v) * ss for v in (x0, y0, x1, y1)]

        d.rounded_rectangle(R(0, 0, gw, gh), 16 * ss, fill=(255, 255, 255), outline=(214, 219, 228),
                            width=ss)
        # Title bar
        d.rounded_rectangle(R(0, 0, gw, 52), 16 * ss, fill=(240, 242, 246))
        d.rectangle(R(0, 30, gw, 52), fill=(240, 242, 246))
        d.line(R(0, 52, gw, 52)[:2] + R(0, 52, gw, 52)[2:], fill=(222, 226, 233), width=ss)
        for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
            cx = 24 + i * 20
            d.ellipse(R(cx - 6, 20, cx + 6, 32), fill=c)
        d.rounded_rectangle(R(110, 14, gw - 30, 38), 8 * ss, fill=(255, 255, 255))
        f_url = font(15 * ss)
        d.text(((pad + 126) * ss, (pad + 17) * ss), "usps.com/pickup", font=f_url, fill=(120, 124, 132))
        # Sign-in form
        f_h = font(26 * ss, "Semibold")
        f_l = font(14 * ss)
        d.text(((pad + 48) * ss, (pad + 84) * ss), "Sign in", font=f_h, fill=INK)
        for i, label in enumerate(["Username", "Password"]):
            y = 140 + i * 74
            d.text(((pad + 48) * ss, (pad + y) * ss), label, font=f_l, fill=SUB)
            d.rounded_rectangle(R(48, y + 22, gw - 48, y + 56), 8 * ss, fill=(248, 249, 251),
                                outline=(204, 209, 218), width=ss)
        d.text(((pad + 62) * ss, (pad + 238 + 6) * ss), "•" * 9, font=f_l, fill=(150, 154, 162))
        d.rounded_rectangle(R(48, 302, gw - 48, 342), 10 * ss, fill=(207, 214, 226))
        f_b = font(16 * ss, "Semibold")
        d.text(((pad + 48 + 34) * ss, (pad + 312) * ss), "Signing in", font=f_b, fill=(255, 255, 255))
        img = img.resize((gw + pad * 2, gh + pad * 2), Image.LANCZOS)
        out = shadow.copy()
        out.alpha_composite(img)
        return out, (pad + 48 + 18, pad + 322)

    def _spinner_frames(self, size):
        ss, n = 4, 12
        frames = []
        for k in range(n):
            big = Image.new("RGBA", (size * ss, size * ss), (0, 0, 0, 0))
            d = ImageDraw.Draw(big)
            c = size * ss / 2
            for i in range(n):
                ang = 2 * math.pi * i / n
                age = (k - i) % n
                a = max(40, 255 - age * 20)
                r0, r1 = size * ss * 0.18, size * ss * 0.32
                d.line([(c + r0 * math.sin(ang), c - r0 * math.cos(ang)),
                        (c + r1 * math.sin(ang), c - r1 * math.cos(ang))],
                       fill=(255, 255, 255, a), width=round(size * ss * 0.07))
            frames.append(big.resize((size // 2, size // 2), Image.LANCZOS))
        return frames

    def form(self):
        """The pickup form, with a slow push-in on the day chips, then a move
        down to the package counts."""
        layer = text_layer([("Pick a day. Count your packages.", F_HEAD, INK, 0),
                            ("Location, weight, and a hazmat check.", F_SUB, SUB, 18)], TEXT_W)
        c = self.card("03-form")
        ZOOM = 1.18
        days, packages = 0.16, 0.56     # chip row and package counts, as fractions of the height

        def camera(fy, scale, pull):
            """Card centre that brings source row `fy` `pull` of the way to mid-frame."""
            offset = (fy - 0.5) * c.size[1] * scale
            return (CARD_CX, H / 2 - offset * pull)

        def render(t, dur):
            f = self.blank()
            appear = ease(t / 0.6)
            t1 = 0.8                    # hold, then push in toward the days
            t2 = dur * 0.42             # then move down to the packages
            t3 = dur - 1.7              # then ease back out to the whole form
            if t < t2:
                p = ease((t - t1) / (t2 - t1 - 0.4))
                scale, fy, pull = lerp(1.0, ZOOM, p), days, 0.5 * p
            elif t < t3:
                p = ease((t - t2) / min(2.6, t3 - t2))
                scale, fy, pull = ZOOM, lerp(days, packages, p), 0.5
            else:
                p = ease((t - t3) / 1.5)
                scale, fy, pull = lerp(ZOOM, 1.0, p), packages, 0.5 * (1 - p)
            c.draw(f, scale, camera(fy, scale, pull), alpha=appear)
            self.caption(f, layer, t)
            return f
        return render

    def outro(self):
        icon = self.icon.resize((150, 150), Image.LANCZOS)
        shadow, pad = shadow_for((132, 132), 30, blur=16, offset=(0, 10), opacity=50)
        head = text_layer([("Free & open source", F_HEAD, INK, 0)], 900, "center")
        url = text_layer([("github.com/toddanglin/usps-pickup-scheduler", F_URL, ACCENT, 0)], 900,
                         "center")
        credit = self._credit()

        def render(t, dur):
            f = self.blank()
            p = ease(t / 0.8)
            cx = W / 2
            paste_fade(f, shadow, (cx - shadow.size[0] / 2, 150 + 9 - pad + 10), p)
            paste_fade(f, icon, (cx - 75, 150), p)
            q = ease((t - 0.35) / 0.7)
            paste_fade(f, head, (cx - 450, 338 + 20 * (1 - q)), q)
            r = ease((t - 0.7) / 0.7)
            paste_fade(f, url, (cx - 450, 410 + 20 * (1 - r)), r)
            s = ease((t - 1.1) / 0.7)
            paste_fade(f, credit, (cx - credit.size[0] / 2, 520 + 20 * (1 - s)), s)
            return f
        return render

    def _credit(self):
        """'Made with <robot> by @toddanglin', with the Apple Color Emoji robot
        when available (it only renders at its bitmap size, so scale it)."""
        before, after = "Made with ", " by @toddanglin"
        emoji = None
        path = "/System/Library/Fonts/Apple Color Emoji.ttc"
        if os.path.exists(path):
            try:
                ef = ImageFont.truetype(path, 160)
                big = Image.new("RGBA", (200, 200), (0, 0, 0, 0))
                ImageDraw.Draw(big).text((20, 20), "\U0001F916", font=ef, embedded_color=True)
                bbox = big.getbbox()
                if bbox:
                    emoji = big.crop(bbox).resize((26, 26), Image.LANCZOS)
            except Exception:
                emoji = None
        w1, w2 = F_SMALL.getlength(before), F_SMALL.getlength(after)
        ew = 30 if emoji else 0
        img = Image.new("RGBA", (round(w1 + ew + w2) + 4, 34), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.text((0, 4), before if emoji else "Made by @toddanglin", font=F_SMALL, fill=SUB + (255,))
        if emoji:
            img.alpha_composite(emoji, (round(w1) + 2, 3))
            d.text((w1 + ew, 4), after, font=F_SMALL, fill=SUB + (255,))
        return img


def storyboard(s):
    return [
        (4, "Pickup schedules USPS carrier pickups right from your Mac's menu bar.", s.title()),
        (6, "Scheduling on usps.com means signing in and re-entering your address, every single time.",
         s.problem()),
        (7, "Connect once with your free USPS developer key. It's stored in your Keychain, and tokens "
            "renew themselves, so you never log in again.",
         s.card_scene(["01-onboarding"], "Connect once with your free USPS API key.",
                      "Stored in your Keychain. Tokens renew themselves.")),
        (6, "USPS verifies your pickup address, once.",
         s.card_scene(["02b-address-verified"], "USPS verifies your pickup address.", "Once.")),
        (9, "Then each pickup is a few clicks: pick a day, count your packages by service, set the "
            "location and weight, and confirm there's no hazmat.", s.form()),
        (7, "One click, and you have a USPS confirmation number in seconds.",
         s.card_scene(["03-form", "05-confirmation"], "One click. Confirmation in seconds.",
                      "Copy the number or schedule another.", switch_at=1.6,
                      # The Schedule Pickup button. (04-scheduling is caught mid-cross-fade
                      # between the form and the progress view, so it is not used.)
                      press=(0.7, (16 / 340, 560 / 637, 324 / 340, 588 / 637)))),
        (8, "Every pickup you schedule is listed, and you can modify or cancel it without leaving "
            "the menu bar.",
         s.card_scene(["08-history", "09b0-cancel-confirm"], "See, modify, or cancel scheduled pickups.",
                      None, switch_at=3.6)),
        (5, "Pickup is free and open source. Grab it on GitHub.", s.outro()),
    ]


# --------------------------------------------------------------------------
# Audio


def narrate(work, index, text):
    aiff = os.path.join(work, f"scene{index}.aiff")
    wav = os.path.join(work, f"scene{index}.wav")
    subprocess.run(["say", "-v", SAY_VOICE, "-r", SAY_RATE, "-o", aiff, text], check=True)
    subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-i", aiff, "-ac", "1", "-ar",
                    str(AUDIO_RATE), "-sample_fmt", "s16", wav], check=True)
    out = subprocess.run([FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of",
                          "default=nw=1:nk=1", wav], capture_output=True, text=True, check=True)
    return wav, float(out.stdout.strip())


def mix_audio(path, clips, total):
    """Lay each (wav, start seconds) onto one silent mono track."""
    buf = bytearray(int(total * AUDIO_RATE) * 2)
    for wav, start in clips:
        with wave.open(wav) as w:
            data = w.readframes(w.getnframes())
        at = int(start * AUDIO_RATE) * 2
        data = data[: max(0, len(buf) - at)]
        buf[at:at + len(data)] = data
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(AUDIO_RATE)
        w.writeframes(bytes(buf))


# --------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--screens", default=os.path.join(ROOT, ".build/explainer-screens"))
    ap.add_argument("--out", default=os.path.join(ROOT, "docs"))
    ap.add_argument("--work", default=os.path.join(ROOT, ".build/explainer"))
    ap.add_argument("--gif-dither", default="bayer:bayer_scale=5")
    ap.add_argument("--narrate", action="store_true",
                    help="include the synthesized narration track in the MP4 (off by default; "
                         "the narration is still generated to pace the scenes)")
    ap.add_argument("--still", type=float, action="append", default=[],
                    help="only write the frame at this time (seconds) to --work; repeatable")
    args = ap.parse_args()
    os.makedirs(args.work, exist_ok=True)
    os.makedirs(args.out, exist_ok=True)

    scenes = storyboard(Scenes(args.screens))
    timeline, clips, start = [], [], 0.0
    for i, (minimum, text, render) in enumerate(scenes, 1):
        wav, length = narrate(args.work, i, text)
        dur = max(length + VOICE_DELAY + VOICE_TAIL, minimum)
        dur = math.ceil(dur * FPS) / FPS
        timeline.append((start, dur, render))
        clips.append((wav, start + VOICE_DELAY))
        print(f"scene {i}: narration {length:.2f}s -> {dur:.2f}s at {start:.2f}s")
        start += dur
    total = start
    print(f"total {total:.2f}s")

    audio = os.path.join(args.work, "narration.wav")
    mix_audio(audio, clips, total)

    mp4 = os.path.join(args.out, "explainer.mp4")
    def frame_at(t):
        k = max(i for i, (s0, _, _) in enumerate(timeline) if s0 <= t + 1e-9)
        s0, dur, render = timeline[k]
        local = t - s0
        frame = render(local, dur)
        if k > 0 and local < DISSOLVE:
            ps0, pdur, prender = timeline[k - 1]
            frame = Image.blend(prender(t - ps0, pdur), frame, ease(local / DISSOLVE))
        return frame

    if args.still:
        for t in args.still:
            path = os.path.join(args.work, f"still-{t:05.1f}.png")
            frame_at(t).convert("RGB").save(path)
            print(path)
        return 0

    frames = round(total * FPS)
    enc = subprocess.Popen([
        FFMPEG, "-y", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
        *(["-i", audio] if args.narrate else []),
        "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-tune", "stillimage",
        "-pix_fmt", "yuv420p",
        *(["-c:a", "aac", "-b:a", "96k", "-shortest"] if args.narrate else ["-an"]),
        "-movflags", "+faststart", mp4], stdin=subprocess.PIPE)

    for n in range(frames):
        enc.stdin.write(frame_at(n / FPS).convert("RGB").tobytes())
        if n % (FPS * 5) == 0:
            print(f"  frame {n}/{frames}", flush=True)
    enc.stdin.close()
    if enc.wait() != 0:
        sys.exit("make-explainer: ffmpeg failed encoding the MP4")

    gif = os.path.join(args.out, "explainer.gif")
    palette = os.path.join(args.work, "palette.png")
    scale = "fps=12,scale=640:360:flags=lanczos"
    subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-i", mp4, "-vf",
                    f"{scale},palettegen=max_colors=256:stats_mode=full", palette], check=True)
    subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-i", mp4, "-i", palette, "-lavfi",
                    f"{scale}[v];[v][1:v]paletteuse=dither={args.gif_dither}:diff_mode=rectangle",
                    "-loop", "0", gif], check=True)
    for p in (mp4, gif):
        print(f"{p}: {os.path.getsize(p) / 1e6:.2f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
