/**
 * sprites.js — Whiplash Dashboard pixel art (v3.2 — CHUNKY)
 */

const PAL = {
  floor: '#c4a882', floorAlt: '#b89e78', floorLine: '#a08a68',
  loungeFloor: '#6b7b6b', loungeAlt: '#5e6e5e', loungeLine: '#4a5a4a',
  darkFloor: '#1e2028', darkAlt: '#24262e', darkLine: '#16181e',
  wallTop: '#e8ddd0', wallFace: '#d4c8b8', wallDark: '#b8a898', outline: '#2a2428',
  wood: '#b07840', woodDark: '#8a5a2c', woodLight: '#c89050',
  chairSeat: '#404850', chairBack: '#303840', chairWheel: '#282830',
  bez: '#d8d8dc', bezDark: '#b0b0b8',
  screenOn: '#0a1a10', screenCode: '#22cc55', screenOff: '#08080a',
  skin: '#f0c8a8', hairBlack: '#1a1418', hairBrown: '#5a3828', hairLight: '#8a6848',
  sofaFabric: '#5878a8', sofaDark: '#3a5478', sofaArm: '#486890',
  rugWarm: '#a86848', rugDark: '#884838', tableCoffee: '#9a7248',
  mugWhite: '#e8e8e8', coffee: '#6a3818',
  glow: '#00ff66', consoleMetal: '#484c54', consoleEdge: '#383c44',
  rackDark: '#1a1c22', rackLed: '#00ee44', rackLedWarn: '#ee3333',
  bubbleBg: 'rgba(255,255,255,0.95)', bubbleErr: '#dd3344',
  badgeRed: '#ee2233', textDark: '#1a1418',
};

const ROLE_THEME = {
  manager:    { hair: PAL.hairBlack, shirt: '#4070a8', accent: '#5088c0', label: 'MANAGER' },
  researcher: { hair: PAL.hairBrown, shirt: '#2a8858', accent: '#38a868', label: 'RESEARCHER' },
  developer:  { hair: PAL.hairBlack, shirt: '#a04848', accent: '#c05858', label: 'DEVELOPER' },
  monitoring: { hair: PAL.hairLight, shirt: '#c0a030', accent: '#d8b840', label: 'MONITOR' },
};

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y); ctx.lineTo(x + w - r, y);
  ctx.quadraticCurveTo(x + w, y, x + w, y + r); ctx.lineTo(x + w, y + h - r);
  ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h); ctx.lineTo(x + r, y + h);
  ctx.quadraticCurveTo(x, y + h, x, y + h - r); ctx.lineTo(x, y + r);
  ctx.quadraticCurveTo(x, y, x + r, y); ctx.closePath();
}

function OL(ctx, x, y, w, h) {
  ctx.strokeStyle = PAL.outline; ctx.lineWidth = 2; ctx.strokeRect(x, y, w, h);
}

// ── Environment ───────────────────────────────────────────

const Env = {
  drawFloor(ctx, x, y, w, h, type) {
    let base, alt, line;
    if (type === 'lounge') { base = PAL.loungeFloor; alt = PAL.loungeAlt; line = PAL.loungeLine; }
    else if (type === 'dark') { base = PAL.darkFloor; alt = PAL.darkAlt; line = PAL.darkLine; }
    else { base = PAL.floor; alt = PAL.floorAlt; line = PAL.floorLine; }
    ctx.fillStyle = base; ctx.fillRect(x, y, w, h);
    const tile = 36;
    for (let ty = 0; ty < Math.ceil(h / tile); ty++)
      for (let tx = 0; tx < Math.ceil(w / tile); tx++)
        if ((tx + ty) % 2 === 0) {
          ctx.fillStyle = alt;
          const px = x + tx * tile, py = y + ty * tile;
          ctx.fillRect(px, py, Math.min(tile, x + w - px), Math.min(tile, y + h - py));
        }
    ctx.fillStyle = line; ctx.globalAlpha = 0.2;
    for (let gx = x; gx <= x + w; gx += tile) ctx.fillRect(gx, y, 1, h);
    for (let gy = y; gy <= y + h; gy += tile) ctx.fillRect(x, gy, w, 1);
    ctx.globalAlpha = 1;
  },
  drawWallH(ctx, x, y, w) {
    ctx.fillStyle = PAL.wallDark; ctx.fillRect(x, y, w, 18);
    ctx.fillStyle = PAL.wallFace; ctx.fillRect(x, y, w, 14);
    ctx.fillStyle = PAL.wallTop; ctx.fillRect(x, y, w, 4);
    ctx.fillStyle = PAL.outline; ctx.fillRect(x, y + 16, w, 2); ctx.fillRect(x, y - 1, w, 1);
  },
  drawWallV(ctx, x, y, h) {
    ctx.fillStyle = PAL.outline; ctx.fillRect(x - 1, y, 14, h);
    ctx.fillStyle = PAL.wallFace; ctx.fillRect(x, y, 12, h);
    ctx.fillStyle = PAL.wallTop; ctx.fillRect(x + 9, y, 3, h);
  },
  drawRug(ctx, x, y, w, h) {
    ctx.fillStyle = PAL.rugWarm; roundRect(ctx, x, y, w, h, 8); ctx.fill();
    ctx.fillStyle = PAL.rugDark; roundRect(ctx, x + 10, y + 8, w - 20, h - 16, 4); ctx.fill();
    ctx.fillStyle = PAL.rugWarm; roundRect(ctx, x + 18, y + 14, w - 36, h - 28, 4); ctx.fill();
  },
};

// ── Furniture (2x scale) ──────────────────────────────────

const Furn = {
  drawDesk(ctx, x, y, w, h) {
    ctx.fillStyle = 'rgba(0,0,0,0.1)'; ctx.fillRect(x + 4, y + h + 3, w, 6);
    ctx.fillStyle = PAL.wood; ctx.fillRect(x, y, w, h);
    ctx.fillStyle = PAL.woodLight; ctx.fillRect(x, y, w, 5);
    ctx.fillStyle = PAL.woodDark; ctx.fillRect(x, y + h, w, 6);
    OL(ctx, x, y, w, h + 6);
  },
  drawMonitor(ctx, x, y, state) {
    const bw = 66, bh = 48;
    ctx.fillStyle = PAL.bezDark;
    ctx.fillRect(x + 25, y + bh + 2, 16, 10);
    ctx.fillRect(x + 15, y + bh + 11, 36, 5);
    ctx.fillStyle = PAL.bez; ctx.fillRect(x, y, bw, bh);
    ctx.fillStyle = PAL.bezDark; ctx.fillRect(x, y + bh - 4, bw, 4);
    OL(ctx, x, y, bw, bh);
    const sx = x + 5, sy = y + 5, sw = bw - 10, sh = bh - 12;
    if (state === 'code' || state === 'rebooting') {
      ctx.fillStyle = PAL.screenOn; ctx.fillRect(sx, sy, sw, sh);
      ctx.fillStyle = PAL.screenCode;
      ctx.fillRect(sx + 4, sy + 4, 18, 3); ctx.fillRect(sx + 6, sy + 11, 24, 3);
      ctx.fillRect(sx + 4, sy + 18, 14, 3); ctx.fillRect(sx + 10, sy + 25, 20, 3);
    } else if (state === 'on') {
      ctx.fillStyle = '#1a3020'; ctx.fillRect(sx, sy, sw, sh);
      ctx.fillStyle = PAL.screenCode; ctx.globalAlpha = 0.3;
      ctx.fillRect(sx + 4, sy + 6, 14, 3); ctx.globalAlpha = 1;
    } else {
      ctx.fillStyle = PAL.screenOff; ctx.fillRect(sx, sy, sw, sh);
    }
  },
  drawKeyboard(ctx, x, y) {
    ctx.fillStyle = PAL.bez; ctx.fillRect(x, y, 50, 20);
    OL(ctx, x, y, 50, 20);
    ctx.fillStyle = PAL.bezDark;
    for (let r = 0; r < 3; r++)
      for (let c = 0; c < 7; c++)
        ctx.fillRect(x + 3 + c * 6, y + 3 + r * 5, 5, 4);
  },
  drawMouse(ctx, x, y) {
    ctx.fillStyle = PAL.bez; roundRect(ctx, x, y, 14, 20, 5); ctx.fill();
    ctx.strokeStyle = PAL.outline; ctx.lineWidth = 2; ctx.stroke();
  },
  drawChair(ctx, x, y, facing) {
    ctx.fillStyle = PAL.chairWheel;
    ctx.fillRect(x + 8, y + 50, 6, 5); ctx.fillRect(x + 32, y + 50, 6, 5);
    ctx.fillStyle = PAL.chairSeat; ctx.fillRect(x + 2, y + 22, 42, 26);
    OL(ctx, x + 2, y + 22, 42, 26);
    if (facing !== 'down') {
      ctx.fillStyle = PAL.chairBack; ctx.fillRect(x + 2, y + 40, 42, 18);
      OL(ctx, x + 2, y + 40, 42, 18);
    } else {
      ctx.fillStyle = PAL.chairBack; ctx.fillRect(x + 2, y, 42, 18);
      OL(ctx, x + 2, y, 42, 18);
    }
  },
  drawSofa(ctx, x, y, w) {
    ctx.fillStyle = 'rgba(0,0,0,0.08)'; ctx.fillRect(x + 3, y + 68, w, 6);
    ctx.fillStyle = PAL.sofaDark; ctx.fillRect(x, y, w, 26);
    OL(ctx, x, y, w, 26);
    ctx.fillStyle = PAL.sofaFabric; ctx.fillRect(x, y + 26, w, 40);
    OL(ctx, x, y + 26, w, 40);
    ctx.fillStyle = PAL.sofaArm;
    ctx.fillRect(x - 10, y + 8, 18, 58); OL(ctx, x - 10, y + 8, 18, 58);
    ctx.fillRect(x + w - 8, y + 8, 18, 58); OL(ctx, x + w - 8, y + 8, 18, 58);
    ctx.fillStyle = PAL.sofaDark;
    ctx.fillRect(x + Math.floor(w / 3), y + 28, 2, 36);
    ctx.fillRect(x + Math.floor(w * 2 / 3), y + 28, 2, 36);
  },
  drawCoffeeTable(ctx, x, y, w, h) {
    ctx.fillStyle = 'rgba(0,0,0,0.06)'; ctx.fillRect(x + 3, y + h + 2, w, 4);
    ctx.fillStyle = PAL.tableCoffee; ctx.fillRect(x, y, w, h);
    ctx.fillStyle = PAL.wood; ctx.fillRect(x, y, w, 4);
    OL(ctx, x, y, w, h);
  },
  drawCoffeeMachine(ctx, x, y) {
    ctx.fillStyle = '#888890'; ctx.fillRect(x, y, 56, 76);
    OL(ctx, x, y, 56, 76);
    ctx.fillStyle = '#1a1a20'; ctx.fillRect(x + 6, y + 12, 44, 28);
    ctx.fillStyle = '#33aa55'; ctx.fillRect(x + 10, y + 18, 8, 8);
    ctx.fillStyle = '#666'; ctx.fillRect(x + 12, y + 48, 32, 22);
  },
  drawPlant(ctx, x, y, size) {
    const s = size === 'large' ? 2.0 : 1.5;
    ctx.fillStyle = '#a06840'; ctx.fillRect(x + 6 * s, y + 26 * s, 22 * s, 16 * s);
    OL(ctx, x + 6 * s, y + 26 * s, 22 * s, 16 * s);
    ctx.fillStyle = '#3a8838';
    ctx.beginPath(); ctx.arc(x + 17 * s, y + 14 * s, 17 * s, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = '#4aa848';
    ctx.beginPath(); ctx.arc(x + 14 * s, y + 11 * s, 10 * s, 0, Math.PI * 2); ctx.fill();
    ctx.strokeStyle = PAL.outline; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.arc(x + 17 * s, y + 14 * s, 17 * s, 0, Math.PI * 2); ctx.stroke();
  },
  drawClock(ctx, x, y) {
    ctx.fillStyle = '#fff';
    ctx.beginPath(); ctx.arc(x + 18, y + 18, 18, 0, Math.PI * 2); ctx.fill();
    ctx.strokeStyle = PAL.outline; ctx.lineWidth = 2; ctx.stroke();
    ctx.fillStyle = '#222'; ctx.fillRect(x + 17, y + 4, 2, 16); ctx.fillRect(x + 17, y + 14, 12, 2);
  },
  drawWhiteboard(ctx, x, y, w, h) {
    ctx.fillStyle = '#f0f0f0'; ctx.fillRect(x, y, w, h);
    OL(ctx, x, y, w, h);
    ctx.strokeStyle = '#3355aa'; ctx.lineWidth = 3;
    ctx.beginPath(); ctx.moveTo(x + 14, y + 12); ctx.lineTo(x + w - 24, y + 20); ctx.stroke();
    ctx.strokeStyle = '#cc3344';
    ctx.beginPath(); ctx.moveTo(x + 20, y + 30); ctx.lineTo(x + w - 16, y + 34); ctx.stroke();
    ctx.lineWidth = 2;
  },
  drawBookshelf(ctx, x, y) {
    ctx.fillStyle = PAL.woodDark; ctx.fillRect(x, y, 70, 84);
    OL(ctx, x, y, 70, 84);
    ctx.fillStyle = PAL.wood;
    ctx.fillRect(x + 3, y + 28, 64, 3); ctx.fillRect(x + 3, y + 56, 64, 3);
    const colors = ['#c04040', '#4060a0', '#40a060', '#c08040', '#8040a0', '#a0a040'];
    for (let s = 0; s < 3; s++) {
      const sy = y + 3 + s * 28;
      for (let b = 0; b < 5; b++) {
        ctx.fillStyle = colors[(s * 5 + b) % colors.length];
        ctx.fillRect(x + 5 + b * 13, sy, 10, 24);
      }
    }
  },
  drawMug(ctx, x, y, hasCoffee) {
    ctx.fillStyle = PAL.mugWhite; ctx.fillRect(x, y, 14, 18);
    OL(ctx, x, y, 14, 18);
    if (hasCoffee) { ctx.fillStyle = PAL.coffee; ctx.fillRect(x + 2, y + 4, 10, 7); }
    ctx.strokeStyle = PAL.mugWhite; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.arc(x + 15, y + 9, 5, -Math.PI / 2, Math.PI / 2); ctx.stroke();
  },
  drawCCTVScreen(ctx, x, y, w, h, label) {
    ctx.fillStyle = '#282830'; ctx.fillRect(x - 5, y - 5, w + 10, h + 10);
    OL(ctx, x - 5, y - 5, w + 10, h + 10);
    ctx.fillStyle = '#060a08'; ctx.fillRect(x, y, w, h);
    ctx.fillStyle = 'rgba(0,200,60,0.04)';
    for (let sy = y; sy < y + h; sy += 4) ctx.fillRect(x, sy, w, 1);
    ctx.fillStyle = PAL.glow; ctx.globalAlpha = 0.8;
    ctx.font = '16px "DungGeunMo", monospace';
    ctx.fillText(label || 'CCTV', x + 10, y + 24);
    ctx.globalAlpha = 1;
    ctx.strokeStyle = 'rgba(0,255,100,0.15)'; ctx.lineWidth = 1;
    ctx.strokeRect(x, y, w, h); ctx.lineWidth = 2;
  },
  drawConsole(ctx, x, y, w, h) {
    ctx.fillStyle = PAL.consoleMetal; ctx.fillRect(x, y, w, h);
    ctx.fillStyle = PAL.consoleEdge; ctx.fillRect(x, y + h - 6, w, 6);
    OL(ctx, x, y, w, h);
    ctx.fillStyle = '#333'; ctx.fillRect(x + 12, y + 10, 36, 14);
    ctx.fillStyle = PAL.rackLed; ctx.fillRect(x + 16, y + 14, 5, 5);
    ctx.fillStyle = '#ee8800'; ctx.fillRect(x + 26, y + 14, 5, 5);
  },
  drawServerRack(ctx, x, y) {
    ctx.fillStyle = PAL.rackDark; ctx.fillRect(x, y, 54, 100);
    OL(ctx, x, y, 54, 100);
    for (let i = 0; i < 3; i++) {
      const sy = y + 10 + i * 28;
      ctx.fillStyle = '#101218'; ctx.fillRect(x + 6, sy, 42, 20);
      ctx.fillStyle = PAL.rackLed; ctx.fillRect(x + 11, sy + 5, 5, 5);
      ctx.fillStyle = i === 2 ? PAL.rackLedWarn : PAL.rackLed;
      ctx.fillRect(x + 21, sy + 5, 5, 5);
    }
  },
};

// ── Characters (2x scale — CHUNKY) ───────────────────────

const Char = {
  drawSitting(ctx, x, y, role, animFrame, angle) {
    const t = ROLE_THEME[role] || ROLE_THEME.developer;
    angle = angle || 'up';

    if (angle === 'up') {
      ctx.fillStyle = t.shirt; ctx.fillRect(x, y + 22, 46, 32);
      OL(ctx, x, y + 22, 46, 32);
      ctx.fillStyle = t.shirt;
      ctx.fillRect(x - 6, y + 18, 10, 28); OL(ctx, x - 6, y + 18, 10, 28);
      ctx.fillRect(x + 42, y + 18, 10, 28); OL(ctx, x + 42, y + 18, 10, 28);
      ctx.fillStyle = PAL.skin;
      const ho = animFrame ? 4 : 0;
      ctx.fillRect(x - 3, y + 2 + ho, 8, 8);
      ctx.fillRect(x + 41, y + 6 - ho, 8, 8);
      ctx.fillStyle = t.hair;
      roundRect(ctx, x + 5, y, 36, 26, 8); ctx.fill();
      ctx.strokeStyle = PAL.outline; ctx.lineWidth = 2; ctx.stroke();
    } else if (angle === 'down') {
      ctx.fillStyle = t.shirt; ctx.fillRect(x, y + 28, 46, 32);
      OL(ctx, x, y + 28, 46, 32);
      ctx.fillStyle = PAL.skin;
      roundRect(ctx, x + 5, y, 36, 30, 8); ctx.fill();
      ctx.strokeStyle = PAL.outline; ctx.lineWidth = 2; ctx.stroke();
      ctx.fillStyle = t.hair;
      roundRect(ctx, x + 5, y, 36, 14, 8); ctx.fill();
      ctx.fillStyle = '#111';
      ctx.fillRect(x + 12, y + 16, 5, 4); ctx.fillRect(x + 29, y + 16, 5, 4);
      ctx.fillRect(x + 19, y + 23, 8, 2);
    }
  },

  drawStanding(ctx, x, y, role, isCoffee) {
    const t = ROLE_THEME[role] || ROLE_THEME.developer;
    ctx.fillStyle = 'rgba(0,0,0,0.08)';
    ctx.beginPath(); ctx.ellipse(x + 23, y + 96, 18, 6, 0, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = '#303840';
    ctx.fillRect(x + 10, y + 68, 12, 26); ctx.fillRect(x + 26, y + 68, 12, 26);
    ctx.fillStyle = t.shirt; ctx.fillRect(x + 3, y + 34, 42, 38);
    OL(ctx, x + 3, y + 34, 42, 38);
    if (isCoffee) {
      ctx.fillStyle = t.shirt; ctx.fillRect(x + 43, y + 38, 10, 18);
      ctx.fillStyle = PAL.skin; ctx.fillRect(x + 46, y + 54, 8, 8);
      Furn.drawMug(ctx, x + 52, y + 50, true);
    }
    ctx.fillStyle = PAL.skin;
    roundRect(ctx, x + 5, y, 36, 36, 8); ctx.fill();
    ctx.strokeStyle = PAL.outline; ctx.lineWidth = 2; ctx.stroke();
    ctx.fillStyle = t.hair;
    roundRect(ctx, x + 5, y, 36, 15, 8); ctx.fill();
    ctx.fillStyle = '#111';
    ctx.fillRect(x + 12, y + 18, 5, 4); ctx.fillRect(x + 29, y + 18, 5, 4);
  },

  drawSleepingSofa(ctx, x, y, role) {
    const t = ROLE_THEME[role] || ROLE_THEME.developer;
    ctx.fillStyle = t.shirt; ctx.fillRect(x, y, 54, 28);
    OL(ctx, x, y, 54, 28);
    ctx.fillStyle = PAL.skin;
    roundRect(ctx, x + 52, y - 4, 26, 26, 6); ctx.fill();
    ctx.strokeStyle = PAL.outline; ctx.lineWidth = 2; ctx.stroke();
    ctx.fillStyle = t.hair;
    roundRect(ctx, x + 52, y - 4, 26, 12, 6); ctx.fill();
    ctx.fillStyle = '#111'; ctx.fillRect(x + 62, y + 12, 5, 2);
  },
};

// ── Effects ───────────────────────────────────────────────

const FX = {
  drawBubble(ctx, x, y, text, isError) {
    if (!text) return;
    ctx.font = 'bold 15px "DungGeunMo", monospace';
    const tw = ctx.measureText(text).width;
    const pw = tw + 24, ph = 28;
    const bx = x - pw / 2, by = y - ph - 14;
    ctx.fillStyle = 'rgba(0,0,0,0.12)';
    roundRect(ctx, bx + 3, by + 3, pw, ph, 6); ctx.fill();
    ctx.fillStyle = isError ? PAL.bubbleErr : PAL.bubbleBg;
    roundRect(ctx, bx, by, pw, ph, 6); ctx.fill();
    ctx.strokeStyle = isError ? '#aa1122' : 'rgba(0,0,0,0.2)';
    ctx.lineWidth = 1; ctx.stroke(); ctx.lineWidth = 2;
    ctx.fillStyle = isError ? PAL.bubbleErr : PAL.bubbleBg;
    ctx.beginPath();
    ctx.moveTo(x - 6, by + ph); ctx.lineTo(x, by + ph + 10); ctx.lineTo(x + 6, by + ph);
    ctx.fill();
    ctx.fillStyle = isError ? '#fff' : PAL.textDark;
    ctx.textAlign = 'center'; ctx.fillText(text, x, by + 20); ctx.textAlign = 'left';
  },

  drawStatusDot(ctx, x, y, state, animFrame) {
    const colors = {
      working: '#00dd66', idle: '#eebb22', sleeping: '#99aacc',
      crashed: '#dd2233', hung: '#ee7700', rebooting: '#3388ee',
      waiting_for_user: '#ff6600',
    };
    const c = colors[state]; if (!c) return;
    if (state === 'rebooting' && animFrame) return;
    ctx.fillStyle = c; ctx.globalAlpha = 0.25;
    ctx.beginPath(); ctx.arc(x, y, 12, 0, Math.PI * 2); ctx.fill();
    ctx.globalAlpha = 1; ctx.fillStyle = c;
    ctx.beginPath(); ctx.arc(x, y, 8, 0, Math.PI * 2); ctx.fill();
    ctx.strokeStyle = PAL.outline; ctx.lineWidth = 1; ctx.stroke(); ctx.lineWidth = 2;
  },

  drawMail(ctx, x, y, count) {
    if (!count) return;
    ctx.fillStyle = PAL.badgeRed;
    ctx.beginPath(); ctx.arc(x, y, 12, 0, Math.PI * 2); ctx.fill();
    ctx.strokeStyle = '#880011'; ctx.lineWidth = 1; ctx.stroke(); ctx.lineWidth = 2;
    ctx.fillStyle = '#fff'; ctx.font = 'bold 14px monospace';
    ctx.textAlign = 'center'; ctx.fillText(count > 9 ? '9+' : String(count), x, y + 5);
    ctx.textAlign = 'left';
  },

  drawZzz(ctx, x, y, animFrame) {
    ctx.font = 'bold 22px monospace'; ctx.fillStyle = '#7788bb';
    const off = animFrame ? -5 : 0;
    ctx.globalAlpha = animFrame ? 0.6 : 1;
    ctx.fillText('z', x, y + off);
    ctx.fillText('z', x + 14, y - 10 + off);
    ctx.fillText('Z', x + 24, y - 24 + off);
    ctx.globalAlpha = 1;
  },

  drawSparks(ctx, x, y, animFrame) {
    const colors = ['#ff3333', '#ffaa00', '#ffee00'];
    const offsets = animFrame ? [[-10, -8], [14, -18], [6, 8]] : [[-8, -16], [10, -4], [-4, 10]];
    for (let i = 0; i < 3; i++) {
      ctx.fillStyle = colors[i]; ctx.fillRect(x + offsets[i][0], y + offsets[i][1], 6, 6);
    }
  },

  drawQuestion(ctx, x, y, animFrame) {
    ctx.fillStyle = '#ee6600'; ctx.font = 'bold 34px monospace';
    ctx.globalAlpha = animFrame ? 0.5 : 1;
    ctx.fillText('?', x, y); ctx.globalAlpha = 1;
  },

  drawAlertBubble(ctx, x, y, text, animFrame) {
    if (!text) text = '유저 응답 대기!';
    ctx.font = 'bold 15px "DungGeunMo", monospace';
    const tw = ctx.measureText(text).width;
    const pw = tw + 24, ph = 28;
    const bx = x - pw / 2, by = y - ph - 14;
    const bounce = animFrame ? -3 : 0;
    ctx.fillStyle = 'rgba(0,0,0,0.12)';
    roundRect(ctx, bx + 3, by + 3 + bounce, pw, ph, 6); ctx.fill();
    ctx.fillStyle = animFrame ? '#ff5500' : '#ff7700';
    roundRect(ctx, bx, by + bounce, pw, ph, 6); ctx.fill();
    ctx.strokeStyle = '#cc3300'; ctx.lineWidth = 1; ctx.stroke(); ctx.lineWidth = 2;
    ctx.fillStyle = animFrame ? '#ff5500' : '#ff7700';
    ctx.beginPath();
    ctx.moveTo(x - 6, by + ph + bounce); ctx.lineTo(x, by + ph + 10 + bounce); ctx.lineTo(x + 6, by + ph + bounce);
    ctx.fill();
    ctx.fillStyle = '#fff';
    ctx.textAlign = 'center'; ctx.fillText(text, x, by + 20 + bounce); ctx.textAlign = 'left';
  },

  drawLoading(ctx, x, y, animFrame) {
    ctx.fillStyle = '#222'; ctx.fillRect(x, y, 56, 12);
    OL(ctx, x, y, 56, 12);
    ctx.fillStyle = '#3388ee'; ctx.fillRect(x + 3, y + 3, animFrame ? 50 : 22, 6);
  },

  drawNameTag(ctx, x, y, name, accent) {
    ctx.font = 'bold 18px "DungGeunMo", monospace';
    const tw = ctx.measureText(name).width;
    const pw = tw + 20, ph = 26;
    ctx.fillStyle = accent || '#444'; ctx.globalAlpha = 0.85;
    roundRect(ctx, x - pw / 2, y, pw, ph, 5); ctx.fill();
    ctx.globalAlpha = 1;
    ctx.fillStyle = '#fff';
    ctx.textAlign = 'center'; ctx.fillText(name, x, y + 19); ctx.textAlign = 'left';
  },
};

window.PAL = PAL; window.ROLE_THEME = ROLE_THEME;
window.Env = Env; window.Furn = Furn; window.Char = Char; window.FX = FX;
