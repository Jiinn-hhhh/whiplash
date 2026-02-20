/**
 * office.js — Whiplash Office (v3.3 — Polished)
 *
 * 1280 x 1100
 * ┌──────────────────────────────────────────────────┐
 * │                  HEADER (40px)                     │
 * ├──────────────────────────────────────────────────┤
 * │                 WORKSPACE                          │
 * │              [MGR 상석 center]                     │
 * │     [RES]                        [DEV]            │  560px
 * ├─────────────────────┬────────────────────────────┤
 * │       LOUNGE        │      MONITORING ROOM        │  464px
 * └─────────────────────┴────────────────────────────┘
 * │                  FOOTER (36px)                     │
 */

const CANVAS_W = 1280;
const CANVAS_H = 1100;
const HEADER_H = 40;
const FOOTER_H = 36;
const POLL_INTERVAL = 3000;
const ANIM_INTERVAL = 500;

const WORKSPACE_H = 560;
const BOTTOM_H = CANVAS_H - HEADER_H - WORKSPACE_H - FOOTER_H;

const WORKSPACE = { x: 0, y: HEADER_H, w: CANVAS_W, h: WORKSPACE_H };

// Bottom rooms — centered split with vertical wall at 660
const WALL_X = 660;
const LOUNGE  = { x: 0,      y: HEADER_H + WORKSPACE_H, w: WALL_X,            h: BOTTOM_H };
const MONROOM = { x: WALL_X, y: HEADER_H + WORKSPACE_H, w: CANVAS_W - WALL_X, h: BOTTOM_H };

// ── Desk positions (symmetric) ────────────────────────────
// Manager: centered at top, facing down
const MGR_DESK = { x: 470, y: 60, w: 340, h: 76 };
// Researcher & Developer: symmetric about center (640)
// RES center = 250, DEV center = 1030 → both 390px from center
const RES_DESK = { x: 120, y: 290, w: 260, h: 76 };
const DEV_DESK = { x: 900, y: 290, w: 260, h: 76 };

let statusData = null, animFrame = 0, lastAnimTime = 0, canvas, ctx, offCanvas, offCtx;

const STATE_LABEL = {
  working: null, idle: '대기중...', sleeping: 'zzZ',
  crashed: 'ERROR!', hung: '응답없음', rebooting: '재부팅중...', offline: null,
  waiting_for_user: '유저 응답 대기!',
};

let _prevWaitingUser = false;

function initOffice(c) {
  canvas = c;
  c.width = CANVAS_W; c.height = CANVAS_H;
  offCanvas = document.createElement('canvas');
  offCanvas.width = CANVAS_W; offCanvas.height = CANVAS_H;
  offCtx = offCanvas.getContext('2d');
  offCtx.imageSmoothingEnabled = false;
  ctx = offCtx;
  requestAnimationFrame(renderLoop);
  pollStatus(); setInterval(pollStatus, POLL_INTERVAL);
  if ('Notification' in window && Notification.permission === 'default') {
    Notification.requestPermission();
  }
}

async function pollStatus() {
  try {
    const input = document.getElementById('project-input');
    const p = input ? input.value.trim() : '';
    if (!p) return;
    const r = await fetch(`/api/status?project=${encodeURIComponent(p)}`);
    if (r.ok) statusData = await r.json();
  } catch (e) { console.warn('Poll:', e); }
}

function renderLoop(ts) {
  if (ts - lastAnimTime > ANIM_INTERVAL) { animFrame = 1 - animFrame; lastAnimTime = ts; }
  render(); requestAnimationFrame(renderLoop);
}

function getAgent(role) {
  if (!statusData || !statusData.agents) return null;
  return Object.values(statusData.agents).find(a => a.role === role) || null;
}
function isMeeting(a) {
  if (!a || !a.current_task) return false;
  const t = a.current_task.toLowerCase();
  return t.includes('회의') || t.includes('meeting') || t.includes('sync');
}
function atDesk(a) {
  if (!a) return false;
  const s = a.state;
  return s !== 'offline' && s !== 'idle' && s !== 'sleeping' && !isMeeting(a);
}
function monSt(a) {
  if (!a) return 'off';
  if (a.state === 'working' || a.state === 'rebooting') return 'code';
  if (a.state === 'idle' || a.state === 'hung' || a.state === 'crashed' || a.state === 'waiting_for_user') return 'on';
  return 'off';
}
function trunc(t, n) { return !t ? null : t.length > n ? t.substring(0, n - 2) + '..' : t; }

// ── Render ─────────────────────────────────────────────────

function render() {
  ctx.fillStyle = '#111118'; ctx.fillRect(0, 0, CANVAS_W, CANVAS_H);
  drawHeader();
  drawWorkspace();
  drawLounge();
  drawMonitorRoom();
  drawFooter();
  drawUserAlert();
  // Double buffer: copy completed frame to visible canvas
  const visCtx = canvas.getContext('2d');
  visCtx.drawImage(offCanvas, 0, 0);
}

// ── Header ─────────────────────────────────────────────────

function drawHeader() {
  ctx.fillStyle = '#18181e'; ctx.fillRect(0, 0, CANVAS_W, HEADER_H);
  ctx.fillStyle = '#2a2a34'; ctx.fillRect(0, HEADER_H - 1, CANVAS_W, 1);

  const proj = statusData ? statusData.project : '...';
  ctx.fillStyle = '#e04060'; ctx.font = 'bold 20px "DungGeunMo", monospace';
  ctx.textAlign = 'center';
  ctx.fillText(`WHIPLASH OFFICE — ${proj}`, CANVAS_W / 2, 28);
  ctx.textAlign = 'left';

  if (statusData && statusData.monitor) {
    const m = statusData.monitor;
    ctx.font = '13px "DungGeunMo", monospace';
    if (m.alive) {
      ctx.fillStyle = '#00dd66'; ctx.fillText('● MONITOR OK', CANVAS_W - 200, 26);
      if (m.heartbeat_age_sec >= 0) {
        ctx.fillStyle = m.heartbeat_age_sec > 90 ? '#dd3344' : '#606878';
        ctx.fillText(`${m.heartbeat_age_sec}s`, CANVAS_W - 80, 26);
      }
    } else {
      ctx.fillStyle = '#dd3344'; ctx.fillText('● MONITOR DOWN', CANVAS_W - 200, 26);
    }
  }
  ctx.fillStyle = '#606878'; ctx.font = '13px "DungGeunMo", monospace';
  ctx.fillText(new Date().toLocaleTimeString('ko-KR', { hour12: false }), 16, 26);
}

// ── Workspace ──────────────────────────────────────────────

function drawWorkspace() {
  const R = WORKSPACE;
  Env.drawFloor(ctx, R.x, R.y, R.w, R.h, 'normal');

  // Walls
  Env.drawWallH(ctx, R.x, R.y, R.w);
  const bwY = R.y + R.h - 18;
  // Bottom wall: door to lounge (left), gap, wall, gap, door to monitor room (right)
  Env.drawWallH(ctx, R.x, bwY, 260);
  Env.drawWallH(ctx, 330, bwY, WALL_X - 330 - 35);
  // vertical divider hint at WALL_X
  Env.drawWallH(ctx, WALL_X - 5, bwY, 10);
  Env.drawWallH(ctx, WALL_X + 65, bwY, CANVAS_W - WALL_X - 65 - 250);
  Env.drawWallH(ctx, CANVAS_W - 250 + 70, bwY, 180);
  Env.drawWallV(ctx, R.x, R.y, R.h);
  Env.drawWallV(ctx, R.x + R.w - 12, R.y, R.h);

  // Wall decorations (centered on top wall)
  Furn.drawWhiteboard(ctx, CANVAS_W / 2 - 70, R.y + 20, 140, 44);
  Furn.drawClock(ctx, CANVAS_W / 2 - 110, R.y + 28);

  // Side decorations (symmetric)
  Furn.drawBookshelf(ctx, R.x + 28, R.y + 50);
  Furn.drawBookshelf(ctx, R.x + CANVAS_W - 100, R.y + 50);
  Furn.drawPlant(ctx, R.x + 34, R.y + 440, 'large');
  Furn.drawPlant(ctx, R.x + CANVAS_W - 80, R.y + 440, 'large');

  // Desks
  drawDeskArea(MGR_DESK, 'manager', 'down');
  drawDeskArea(RES_DESK, 'researcher', 'up');
  drawDeskArea(DEV_DESK, 'developer', 'up');
}

function drawDeskArea(d, role, facing) {
  const R = WORKSPACE;
  const dx = R.x + d.x, dy = R.y + d.y;
  const agent = getAgent(role);
  const on = atDesk(agent);
  const state = agent ? agent.state : null;

  if (facing === 'down') {
    // Manager 상석: chair & char above desk
    const chairX = dx + d.w / 2 - 23, chairY = dy - 52;
    const charX = chairX, charY = dy - 30;

    if (!on) Furn.drawChair(ctx, chairX, chairY, 'down');
    if (on) drawCharFX(charX, charY, role, state, 'down');

    Furn.drawDesk(ctx, dx, dy, d.w, d.h);
    Furn.drawMonitor(ctx, dx + d.w / 2 - 33, dy + 8, monSt(agent));
    Furn.drawKeyboard(ctx, dx + d.w / 2 - 25, dy + d.h - 26);
    Furn.drawMouse(ctx, dx + d.w / 2 + 30, dy + d.h - 24);

    if (on) drawIndicators(dx, dy, d.w, charX, charY, agent, state);

  } else {
    // Researcher / Developer: desk above, char below
    Furn.drawDesk(ctx, dx, dy, d.w, d.h);
    Furn.drawMonitor(ctx, dx + d.w / 2 - 33, dy + 8, monSt(agent));
    Furn.drawKeyboard(ctx, dx + d.w / 2 - 25, dy + d.h - 26);
    Furn.drawMouse(ctx, dx + d.w / 2 + 30, dy + d.h - 24);

    const chairX = dx + d.w / 2 - 23, chairY = dy + d.h + 18;
    const charX = chairX, charY = dy + d.h - 16;

    if (!on) {
      Furn.drawChair(ctx, chairX, chairY, 'up');
      return;
    }

    drawCharFX(charX, charY, role, state, 'up');
    drawIndicators(dx, dy, d.w, charX, charY, agent, state);
  }
}

function drawCharFX(x, y, role, state, angle) {
  if (state === 'crashed') {
    Char.drawSitting(ctx, x, y, role, animFrame, angle);
    FX.drawSparks(ctx, x + 22, y + 6, animFrame);
  } else if (state === 'hung') {
    Char.drawSitting(ctx, x, y, role, 0, angle);
    FX.drawQuestion(ctx, x + 50, y - 10, animFrame);
  } else if (state === 'waiting_for_user') {
    Char.drawSitting(ctx, x, y, role, 0, angle);
  } else {
    Char.drawSitting(ctx, x, y, role, animFrame, angle);
  }
}

function drawIndicators(dx, dy, dw, charX, charY, agent, state) {
  FX.drawStatusDot(ctx, dx + dw + 20, dy + 24, state, animFrame);

  if (state === 'waiting_for_user') {
    const alertText = trunc(agent.current_task, 20) || '유저 응답 대기!';
    FX.drawAlertBubble(ctx, charX + 23, charY - 16, alertText, animFrame);
  } else {
    let bubble = STATE_LABEL[state];
    if (state === 'working') bubble = trunc(agent.current_task, 24) || '작업중...';
    if (state === 'rebooting') FX.drawLoading(ctx, dx + dw / 2 - 28, dy + 22, animFrame);
    if (bubble) FX.drawBubble(ctx, charX + 23, charY - 16, bubble, state === 'crashed');
  }
  if (agent.mailbox_new > 0) FX.drawMail(ctx, dx - 20, dy + 18, agent.mailbox_new);
}

// ── Lounge ─────────────────────────────────────────────────

function drawLounge() {
  const R = LOUNGE;
  Env.drawFloor(ctx, R.x, R.y, R.w, R.h, 'lounge');

  Env.drawWallV(ctx, R.x, R.y, R.h);
  Env.drawWallH(ctx, R.x, R.y + R.h - 18, R.w);
  Env.drawWallV(ctx, R.x + R.w - 12, R.y, R.h);

  // Centered rug
  const rugW = 260, rugH = 170;
  Env.drawRug(ctx, R.x + (R.w - rugW) / 2, R.y + 130, rugW, rugH);

  // Furniture — centered layout
  const cx = R.x + R.w / 2;
  Furn.drawSofa(ctx, cx - 220, R.y + 50, 190);
  Furn.drawSofa(ctx, cx + 30, R.y + 50, 170);
  Furn.drawCoffeeTable(ctx, cx - 190, R.y + 148, 140, 52);
  Furn.drawCoffeeTable(ctx, cx + 50, R.y + 148, 130, 48);
  Furn.drawCoffeeMachine(ctx, R.x + R.w - 90, R.y + 40);
  Furn.drawPlant(ctx, R.x + 36, R.y + 350, 'small');
  Furn.drawPlant(ctx, R.x + R.w - 70, R.y + 350, 'small');
  Furn.drawPlant(ctx, R.x + 36, R.y + 50, 'small');

  if (!statusData || !statusData.agents) return;

  // Idle/sleeping agents in lounge
  const standSpots = [
    { x: R.w / 2 - 40, y: 270 },
    { x: R.w / 2 + 100, y: 280 },
    { x: R.w / 2 - 160, y: 290 },
    { x: R.w / 2 + 220, y: 260 },
  ];
  let idx = 0;

  for (const agent of Object.values(statusData.agents)) {
    if (agent.state !== 'idle' && agent.state !== 'sleeping') continue;
    const t = ROLE_THEME[agent.role];

    if (agent.state === 'sleeping') {
      const sx = idx === 0 ? cx - 200 : cx + 50;
      const sy = R.y + 68;
      Char.drawSleepingSofa(ctx, sx, sy, agent.role);
      FX.drawZzz(ctx, sx + 74, sy - 14, animFrame);
      FX.drawNameTag(ctx, sx + 27, sy + 40, t.label, t.accent);
    } else {
      const sp = standSpots[idx % standSpots.length];
      const ax = R.x + sp.x, ay = R.y + sp.y;
      Char.drawStanding(ctx, ax, ay, agent.role, true);
      FX.drawStatusDot(ctx, ax + 52, ay - 4, agent.state, animFrame);
      FX.drawNameTag(ctx, ax + 23, ay + 104, t.label, t.accent);
      if (agent.mailbox_new > 0) FX.drawMail(ctx, ax - 14, ay - 4, agent.mailbox_new);
    }
    idx++;
  }
}

// ── Monitor Room ───────────────────────────────────────────

function drawMonitorRoom() {
  const R = MONROOM;
  Env.drawFloor(ctx, R.x, R.y, R.w, R.h, 'dark');

  Env.drawWallH(ctx, R.x, R.y + R.h - 18, R.w);
  Env.drawWallV(ctx, R.x + R.w - 12, R.y, R.h);

  // CCTV centered in room
  const scrW = 380, scrH = 160;
  const scrX = R.x + (R.w - scrW) / 2;
  Furn.drawCCTVScreen(ctx, scrX, R.y + 28, scrW, scrH, 'SYSTEM MONITOR');

  // Console centered below screen
  const conW = 280;
  Furn.drawConsole(ctx, R.x + (R.w - conW) / 2, R.y + 206, conW, 56);

  // Server racks (right side, stacked)
  Furn.drawServerRack(ctx, R.x + R.w - 130, R.y + 40);
  Furn.drawServerRack(ctx, R.x + R.w - 70, R.y + 40);

  // Chair + monitoring agent (centered below console)
  const chairX = R.x + R.w / 2 - 23, chairY = R.y + 290;
  const mon = getAgent('monitoring');
  const on = mon && mon.state !== 'offline' && mon.state !== 'idle' && mon.state !== 'sleeping';

  if (on) {
    const charX = chairX, charY = chairY - 36;
    const state = mon.state;
    drawCharFX(charX, charY, 'monitoring', state, 'up');
    FX.drawStatusDot(ctx, charX + 56, charY + 8, state, animFrame);
    FX.drawNameTag(ctx, charX + 23, chairY + 30, 'MONITOR', ROLE_THEME.monitoring.accent);
    let text = STATE_LABEL[state] || '감시중...';
    FX.drawBubble(ctx, charX + 23, charY - 20, text, state === 'crashed');
    if (mon.mailbox_new > 0) FX.drawMail(ctx, charX - 18, charY + 8, mon.mailbox_new);
  } else {
    Furn.drawChair(ctx, chairX, chairY, 'up');
    FX.drawNameTag(ctx, chairX + 23, chairY + 60, 'MONITOR', ROLE_THEME.monitoring.accent);
  }

  // Ambient glow
  ctx.fillStyle = 'rgba(0,255,80,0.015)'; ctx.fillRect(R.x, R.y, R.w, R.h);
}

// ── Footer ─────────────────────────────────────────────────

function drawFooter() {
  const fy = CANVAS_H - FOOTER_H;
  ctx.fillStyle = '#18181e'; ctx.fillRect(0, fy, CANVAS_W, FOOTER_H);
  ctx.fillStyle = '#2a2a34'; ctx.fillRect(0, fy, CANVAS_W, 1);
  ctx.font = '13px "DungGeunMo", monospace';

  if (statusData) {
    const ts = new Date(statusData.timestamp * 1000).toLocaleTimeString('ko-KR', { hour12: false });
    ctx.fillStyle = '#505868'; ctx.fillText(`updated ${ts}`, 16, fy + 24);
  } else {
    ctx.fillStyle = '#505868'; ctx.fillText('waiting for data...', 16, fy + 24);
  }

  if (statusData && statusData.agents) {
    const counts = {};
    for (const a of Object.values(statusData.agents)) counts[a.state] = (counts[a.state] || 0) + 1;
    ctx.fillStyle = '#404858'; ctx.textAlign = 'center';
    ctx.fillText(Object.entries(counts).map(([s, c]) => `${s}: ${c}`).join('   '), CANVAS_W / 2, fy + 24);
    ctx.textAlign = 'left';
  }

  ctx.fillStyle = '#383848'; ctx.textAlign = 'right';
  ctx.fillText('3s polling · 1280×1100', CANVAS_W - 16, fy + 24);
  ctx.textAlign = 'left';
}

// ── User Alert Banner + Notification ──────────────────────

function drawUserAlert() {
  if (!statusData || !statusData.agents) { _prevWaitingUser = false; return; }
  const waiting = Object.values(statusData.agents).find(a => a.state === 'waiting_for_user');
  if (!waiting) { _prevWaitingUser = false; return; }

  // Flashing banner across workspace top
  const alpha = animFrame ? 0.95 : 0.75;
  ctx.fillStyle = `rgba(255, 85, 0, ${alpha})`;
  ctx.fillRect(0, HEADER_H, CANVAS_W, 32);
  ctx.fillStyle = '#fff';
  ctx.font = 'bold 16px "DungGeunMo", monospace';
  ctx.textAlign = 'center';
  const label = waiting.role.toUpperCase();
  ctx.fillText(`!! ${label} — 유저 응답을 기다리고 있습니다 !!`, CANVAS_W / 2, HEADER_H + 22);
  ctx.textAlign = 'left';

  // Browser notification (once per transition)
  if (!_prevWaitingUser) {
    _prevWaitingUser = true;
    if ('Notification' in window && Notification.permission === 'granted') {
      new Notification('Whiplash Office', {
        body: `${label} 가 유저 응답을 기다리고 있습니다`,
      });
    }
  }
}

window.initOffice = initOffice;
window.pollStatus = pollStatus;
