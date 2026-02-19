/**
 * office.js — Whiplash Office rendering engine
 *
 * 640x480 Canvas, pixel art office with agent characters.
 * Depends on sprites.js (loaded first).
 */

// ── Constants ──────────────────────────────────────────────
const CANVAS_W = 640;
const CANVAS_H = 480;
const BG_COLOR = '#1a1a2e';
const WALL_COLOR = '#16213e';
const FLOOR_COLOR = '#0f3460';
const GRID_COLOR = '#152548';
const HEADER_H = 36;
const POLL_INTERVAL = 3000;
const ANIM_INTERVAL = 500; // ms per animation frame

// ── Room Layout ────────────────────────────────────────────
// Coordinates in canvas pixels (not scaled sprite units)
const ROOMS = {
  manager: {
    label: 'Manager Room',
    x: 0, y: HEADER_H,
    w: 200, h: 200,
    deskX: 60, deskY: 90,
    chairX: 68, chairY: 138,
    monitorX: 72, monitorY: 46,
    charX: 56, charY: 60,
    color: '#e63946',
  },
  shared: {
    label: 'Shared Space',
    x: 200, y: HEADER_H,
    w: 440, h: 100,
    whiteboardX: 370, whiteboardY: 46,
    color: '#adb5bd',
  },
  researcher: {
    label: 'Research Lab',
    x: 0, y: HEADER_H + 200,
    w: 220, h: 244,
    deskX: 60, deskY: 70,
    chairX: 68, chairY: 118,
    monitorX: 72, monitorY: 26,
    charX: 56, charY: 40,
    bookshelfX: 140, bookshelfY: 100,
    color: '#457b9d',
  },
  developer: {
    label: 'Dev Workshop',
    x: 220, y: HEADER_H + 100,
    w: 220, h: 344,
    deskX: 60, deskY: 70,
    chairX: 68, chairY: 118,
    monitorX: 72, monitorY: 26,
    charX: 56, charY: 40,
    color: '#2a9d8f',
  },
  monitoring: {
    label: 'Monitor Station',
    x: 440, y: HEADER_H + 100,
    w: 200, h: 344,
    deskX: 50, deskY: 70,
    chairX: 58, chairY: 118,
    monitorX: 62, monitorY: 26,
    charX: 46, charY: 40,
    serverX: 130, serverY: 60,
    color: '#f4a261',
  },
};

// ── State ──────────────────────────────────────────────────
let statusData = null;
let animFrame = 0;       // toggles 0/1 every ANIM_INTERVAL
let lastAnimTime = 0;
let particles = [];      // spark/smoke particles for crashed state
let canvas, ctx;

// ── Status dot colors ──────────────────────────────────────
const STATE_DOT = {
  working:   '#00ff88',
  idle:      '#ffd93d',
  sleeping:  '#cccccc',
  crashed:   '#ff4444',
  hung:      '#ff8800',
  rebooting: '#4488ff',
  offline:   null,
};

// ── State labels (Korean) ──────────────────────────────────
const STATE_LABEL = {
  working:   null, // show task name instead
  idle:      '대기중...',
  sleeping:  'zzZ',
  crashed:   'ERROR!',
  hung:      '응답없음...',
  rebooting: '재부팅중...',
  offline:   null,
};

// ── Initialize ─────────────────────────────────────────────
function initOffice(canvasEl) {
  canvas = canvasEl;
  ctx = canvas.getContext('2d');
  canvas.width = CANVAS_W;
  canvas.height = CANVAS_H;

  // Disable smoothing for crisp pixels
  ctx.imageSmoothingEnabled = false;

  // Start animation loop
  requestAnimationFrame(renderLoop);

  // Start polling
  pollStatus();
  setInterval(pollStatus, POLL_INTERVAL);
}

// ── Polling ────────────────────────────────────────────────
async function pollStatus() {
  try {
    const projectInput = document.getElementById('project-input');
    const project = projectInput ? projectInput.value.trim() : '';
    if (!project) return;

    const resp = await fetch(`/api/status?project=${encodeURIComponent(project)}`);
    if (resp.ok) {
      statusData = await resp.json();
      if (statusData.error) {
        console.warn('Status error:', statusData.error);
      }
    }
  } catch (e) {
    console.warn('Poll failed:', e);
  }
}

// ── Render Loop (60fps) ────────────────────────────────────
function renderLoop(timestamp) {
  // Update animation frame
  if (timestamp - lastAnimTime > ANIM_INTERVAL) {
    animFrame = 1 - animFrame;
    lastAnimTime = timestamp;
    updateParticles();
  }

  render(timestamp);
  requestAnimationFrame(renderLoop);
}

// ── Main Render ────────────────────────────────────────────
function render(timestamp) {
  // Clear
  ctx.fillStyle = BG_COLOR;
  ctx.fillRect(0, 0, CANVAS_W, CANVAS_H);

  // Header
  drawHeader();

  // Rooms
  drawRooms();

  // Agents
  if (statusData && statusData.agents) {
    drawAgents(timestamp);
  }

  // Monitor health indicator
  drawMonitorHealth();

  // Footer
  drawFooter();
}

// ── Header ─────────────────────────────────────────────────
function drawHeader() {
  ctx.fillStyle = '#0f3460';
  ctx.fillRect(0, 0, CANVAS_W, HEADER_H);

  ctx.fillStyle = '#e94560';
  ctx.font = 'bold 16px "DungGeunMo", "Galmuri11", monospace';
  ctx.textAlign = 'center';
  const project = statusData ? statusData.project : '...';
  ctx.fillText(`WHIPLASH OFFICE — ${project}`, CANVAS_W / 2, 24);
  ctx.textAlign = 'left';
}

// ── Rooms ──────────────────────────────────────────────────
function drawRooms() {
  for (const [key, room] of Object.entries(ROOMS)) {
    // Floor
    ctx.fillStyle = FLOOR_COLOR;
    ctx.fillRect(room.x, room.y, room.w, room.h);

    // Floor grid pattern
    ctx.strokeStyle = GRID_COLOR;
    ctx.lineWidth = 1;
    for (let gx = room.x; gx < room.x + room.w; gx += 24) {
      ctx.beginPath();
      ctx.moveTo(gx, room.y);
      ctx.lineTo(gx, room.y + room.h);
      ctx.stroke();
    }
    for (let gy = room.y; gy < room.y + room.h; gy += 24) {
      ctx.beginPath();
      ctx.moveTo(room.x, gy);
      ctx.lineTo(room.x + room.w, gy);
      ctx.stroke();
    }

    // Walls (border)
    ctx.strokeStyle = WALL_COLOR;
    ctx.lineWidth = 2;
    ctx.strokeRect(room.x, room.y, room.w, room.h);

    // Room label
    ctx.fillStyle = room.color || '#adb5bd';
    ctx.font = '10px "DungGeunMo", "Galmuri11", monospace';
    ctx.fillText(room.label, room.x + 8, room.y + 14);

    // Draw furniture
    if (key === 'shared' && window.SPRITES) {
      drawSprite(ctx, window.SPRITES.furniture.whiteboard,
        room.x + room.whiteboardX, room.y + room.whiteboardY, SCALE);
    }
    if (key !== 'shared') {
      drawRoomFurniture(key, room);
    }
  }
}

// ── Room Furniture ─────────────────────────────────────────
function drawRoomFurniture(role, room) {
  if (!window.SPRITES) return;
  const furn = window.SPRITES.furniture;

  // Desk
  if (room.deskX != null) {
    drawSprite(ctx, furn.desk, room.x + room.deskX, room.y + room.deskY, SCALE);
  }

  // Chair
  if (room.chairX != null) {
    drawSprite(ctx, furn.chair, room.x + room.chairX, room.y + room.chairY, SCALE);
  }

  // Bookshelf (researcher)
  if (room.bookshelfX != null) {
    drawSprite(ctx, furn.bookshelf, room.x + room.bookshelfX, room.y + room.bookshelfY, SCALE);
  }

  // Server rack (monitoring)
  if (room.serverX != null) {
    drawSprite(ctx, furn.server_rack, room.x + room.serverX, room.y + room.serverY, SCALE);
  }
}

// ── Draw Agents ────────────────────────────────────────────
function drawAgents(timestamp) {
  const agents = statusData.agents;

  for (const [key, agent] of Object.entries(agents)) {
    const role = agent.role;
    const room = ROOMS[role];
    if (!room || !room.charX) continue;

    const state = agent.state || 'offline';
    const ax = room.x + room.charX;
    const ay = room.y + room.charY;

    // Monitor screen state
    drawMonitorScreen(role, room, state);

    if (state === 'offline') {
      // Empty chair, no character
      continue;
    }

    // Draw character sprite
    drawCharacter(role, state, ax, ay);

    // Status dot
    drawStatusDot(state, ax + CHAR_W * SCALE + 4, ay - 4);

    // Speech bubble
    drawSpeechBubble(agent, state, ax, ay);

    // Mail icon
    if (agent.mailbox_new > 0) {
      drawMailIcon(ax - 14, ay - 4, agent.mailbox_new);
    }

    // Particles for crashed state
    if (state === 'crashed') {
      spawnSparks(ax + CHAR_W * SCALE / 2, ay + CHAR_H * SCALE / 2);
    }
  }

  // Draw particles
  drawParticles();
}

// ── Character Sprite Selection ─────────────────────────────
function drawCharacter(role, state, x, y) {
  if (!window.SPRITES) {
    // Fallback: colored circle
    drawFallbackCharacter(role, state, x, y);
    return;
  }

  const charSprites = window.SPRITES.characters[role];
  if (!charSprites) {
    drawFallbackCharacter(role, state, x, y);
    return;
  }

  let sprite;
  switch (state) {
    case 'working':
      sprite = animFrame === 0 ? charSprites.working : charSprites.working2;
      break;
    case 'idle':
    case 'hung':
      sprite = charSprites.idle;
      break;
    case 'sleeping':
      sprite = charSprites.sleeping;
      break;
    case 'crashed':
      sprite = animFrame === 0 ? charSprites.working : charSprites.idle;
      break;
    case 'rebooting':
      // Slight offset for "spinning" effect
      sprite = animFrame === 0 ? charSprites.working : charSprites.working2;
      break;
    default:
      sprite = charSprites.idle;
  }

  drawSprite(ctx, sprite, x, y, SCALE);

  // Sleeping zzZ overlay
  if (state === 'sleeping' && animFrame === 0) {
    ctx.fillStyle = '#8888cc';
    ctx.font = 'bold 14px "DungGeunMo", "Galmuri11", monospace';
    ctx.fillText('z', x + CHAR_W * SCALE + 2, y - 2);
    ctx.fillText('z', x + CHAR_W * SCALE + 10, y - 10);
    ctx.fillText('Z', x + CHAR_W * SCALE + 16, y - 20);
  }

  // Hung "?" overlay
  if (state === 'hung') {
    ctx.fillStyle = '#ff8800';
    ctx.font = 'bold 18px "DungGeunMo", "Galmuri11", monospace';
    ctx.fillText('?', x + CHAR_W * SCALE / 2 - 4, y - 6);
  }
}

// ── Fallback (no sprites loaded) ───────────────────────────
function drawFallbackCharacter(role, state, x, y) {
  const colors = {
    manager: '#e63946', researcher: '#457b9d',
    developer: '#2a9d8f', monitoring: '#f4a261',
  };
  const r = 16;
  const cx = x + CHAR_W * SCALE / 2;
  const cy = y + CHAR_H * SCALE / 2;

  ctx.beginPath();
  ctx.arc(cx, cy, r, 0, Math.PI * 2);
  ctx.fillStyle = state === 'offline' ? '#333' : (colors[role] || '#888');
  ctx.fill();
  ctx.strokeStyle = '#fff';
  ctx.lineWidth = 2;
  ctx.stroke();

  // Role initial
  ctx.fillStyle = '#fff';
  ctx.font = 'bold 14px monospace';
  ctx.textAlign = 'center';
  ctx.fillText(role[0].toUpperCase(), cx, cy + 5);
  ctx.textAlign = 'left';
}

// ── Monitor Screen ─────────────────────────────────────────
function drawMonitorScreen(role, room, state) {
  if (!window.SPRITES || room.monitorX == null) return;
  const furn = window.SPRITES.furniture;

  if (state === 'working' || state === 'rebooting') {
    drawSprite(ctx, furn.monitor_on, room.x + room.monitorX, room.y + room.monitorY, SCALE);
    // Rebooting: draw loading bar on screen
    if (state === 'rebooting') {
      const mx = room.x + room.monitorX + 8 * SCALE;
      const my = room.y + room.monitorY + 4 * SCALE;
      ctx.fillStyle = '#0f3460';
      ctx.fillRect(mx - 6, my - 2, 24, 8);
      const barW = animFrame === 0 ? 12 : 20;
      ctx.fillStyle = '#4488ff';
      ctx.fillRect(mx - 4, my, barW, 4);
    }
  } else if (state === 'idle' || state === 'hung') {
    drawSprite(ctx, furn.monitor_on, room.x + room.monitorX, room.y + room.monitorY, SCALE);
    // Dim overlay
    ctx.fillStyle = 'rgba(0,0,0,0.4)';
    const sw = 10 * SCALE;
    const sh = 6 * SCALE;
    ctx.fillRect(room.x + room.monitorX + 3 * SCALE, room.y + room.monitorY + 1 * SCALE, sw, sh);
    // Hung: blink
    if (state === 'hung' && animFrame === 1) {
      ctx.fillStyle = 'rgba(255,136,0,0.3)';
      ctx.fillRect(room.x + room.monitorX + 3 * SCALE, room.y + room.monitorY + 1 * SCALE, sw, sh);
    }
  } else if (state === 'crashed') {
    drawSprite(ctx, furn.monitor_off, room.x + room.monitorX, room.y + room.monitorY, SCALE);
    // Smoke effect
    if (animFrame === 0) {
      ctx.fillStyle = 'rgba(85,85,102,0.6)';
      ctx.fillRect(room.x + room.monitorX + 5 * SCALE, room.y + room.monitorY - 2 * SCALE, 6 * SCALE, 2 * SCALE);
    }
  } else {
    drawSprite(ctx, furn.monitor_off, room.x + room.monitorX, room.y + room.monitorY, SCALE);
  }
}

// ── Status Dot ─────────────────────────────────────────────
function drawStatusDot(state, x, y) {
  const color = STATE_DOT[state];
  if (!color) return;

  // Blink for rebooting
  if (state === 'rebooting' && animFrame === 1) return;

  ctx.beginPath();
  ctx.arc(x, y, 4, 0, Math.PI * 2);
  ctx.fillStyle = color;
  ctx.fill();

  // Glow
  ctx.beginPath();
  ctx.arc(x, y, 6, 0, Math.PI * 2);
  ctx.strokeStyle = color;
  ctx.globalAlpha = 0.3;
  ctx.lineWidth = 2;
  ctx.stroke();
  ctx.globalAlpha = 1.0;
}

// ── Speech Bubble ──────────────────────────────────────────
function drawSpeechBubble(agent, state, charX, charY) {
  let text = STATE_LABEL[state];

  // For working state, show task name
  if (state === 'working') {
    if (agent.current_task) {
      text = agent.current_task;
      // Truncate
      if (text.length > 20) text = text.substring(0, 18) + '..';
    } else {
      text = '작업중...';
    }
  }

  if (!text) return;

  const bx = charX - 4;
  const by = charY - 22;
  const isError = state === 'crashed';

  // Measure text
  ctx.font = '10px "DungGeunMo", "Galmuri11", monospace';
  const tw = ctx.measureText(text).width;
  const pw = tw + 12;
  const ph = 18;

  // Bubble background
  ctx.fillStyle = isError ? '#ff4444' : 'rgba(255,255,255,0.92)';
  roundRect(ctx, bx, by, pw, ph, 4);
  ctx.fill();

  // Bubble tail
  ctx.beginPath();
  ctx.moveTo(bx + 8, by + ph);
  ctx.lineTo(bx + 14, by + ph + 6);
  ctx.lineTo(bx + 18, by + ph);
  ctx.fillStyle = isError ? '#ff4444' : 'rgba(255,255,255,0.92)';
  ctx.fill();

  // Text
  ctx.fillStyle = isError ? '#fff' : '#1a1a2e';
  ctx.fillText(text, bx + 6, by + 13);
}

// ── Mail Icon ──────────────────────────────────────────────
function drawMailIcon(x, y, count) {
  // Envelope shape
  ctx.fillStyle = '#ffd93d';
  ctx.fillRect(x, y, 12, 9);
  ctx.strokeStyle = '#e07b39';
  ctx.lineWidth = 1;
  ctx.strokeRect(x, y, 12, 9);

  // Envelope flap
  ctx.beginPath();
  ctx.moveTo(x, y);
  ctx.lineTo(x + 6, y + 4);
  ctx.lineTo(x + 12, y);
  ctx.strokeStyle = '#e07b39';
  ctx.stroke();

  // Count badge
  if (count > 0) {
    ctx.fillStyle = '#ff4444';
    ctx.beginPath();
    ctx.arc(x + 12, y, 5, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = '#fff';
    ctx.font = 'bold 7px monospace';
    ctx.textAlign = 'center';
    ctx.fillText(count > 9 ? '9+' : String(count), x + 12, y + 3);
    ctx.textAlign = 'left';
  }
}

// ── Spark Particles ────────────────────────────────────────
function spawnSparks(cx, cy) {
  if (particles.length > 40) return;
  for (let i = 0; i < 2; i++) {
    particles.push({
      x: cx + (Math.random() - 0.5) * 30,
      y: cy + (Math.random() - 0.5) * 20,
      vx: (Math.random() - 0.5) * 2,
      vy: -Math.random() * 2,
      life: 20 + Math.random() * 20,
      color: Math.random() > 0.5 ? '#ff6b6b' : '#ffd93d',
      size: 2 + Math.random() * 2,
    });
  }
}

function updateParticles() {
  particles = particles.filter(p => {
    p.x += p.vx;
    p.y += p.vy;
    p.life--;
    return p.life > 0;
  });
}

function drawParticles() {
  for (const p of particles) {
    ctx.globalAlpha = Math.min(1, p.life / 10);
    ctx.fillStyle = p.color;
    ctx.fillRect(p.x, p.y, p.size, p.size);
  }
  ctx.globalAlpha = 1.0;
}

// ── Monitor Health ─────────────────────────────────────────
function drawMonitorHealth() {
  if (!statusData || !statusData.monitor) return;

  const m = statusData.monitor;
  const x = CANVAS_W - 120;
  const y = CANVAS_H - 20;

  ctx.font = '9px "DungGeunMo", "Galmuri11", monospace';

  if (m.alive) {
    ctx.fillStyle = '#00ff88';
    ctx.fillText('● monitor OK', x, y);
    if (m.heartbeat_age_sec >= 0) {
      ctx.fillStyle = m.heartbeat_age_sec > 90 ? '#ff4444' : '#adb5bd';
      ctx.fillText(`(${m.heartbeat_age_sec}s ago)`, x + 76, y);
    }
  } else {
    ctx.fillStyle = '#ff4444';
    ctx.fillText('● monitor DOWN', x, y);
  }
}

// ── Footer ─────────────────────────────────────────────────
function drawFooter() {
  ctx.fillStyle = '#555';
  ctx.font = '9px "DungGeunMo", "Galmuri11", monospace';
  const ts = statusData ? new Date(statusData.timestamp * 1000).toLocaleTimeString() : '--:--:--';
  ctx.fillText(`Last update: ${ts}`, 8, CANVAS_H - 8);
}

// ── Utility: Rounded Rectangle ─────────────────────────────
function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.lineTo(x + w - r, y);
  ctx.quadraticCurveTo(x + w, y, x + w, y + r);
  ctx.lineTo(x + w, y + h - r);
  ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  ctx.lineTo(x + r, y + h);
  ctx.quadraticCurveTo(x, y + h, x, y + h - r);
  ctx.lineTo(x, y + r);
  ctx.quadraticCurveTo(x, y, x + r, y);
  ctx.closePath();
}

// ── Export ──────────────────────────────────────────────────
window.initOffice = initOffice;
window.pollStatus = pollStatus;
