/**
 * sprites.js — Pixel art sprite definitions for Whiplash Dashboard
 *
 * All sprites are 2D arrays of color codes (hex strings).
 * null = transparent pixel.
 * Characters: 16x24, Furniture: 16x16.
 * Rendered at 3x scale on Canvas.
 */

const SCALE = 3;
const CHAR_W = 16;
const CHAR_H = 24;
const FURN_W = 16;
const FURN_H = 16;

// ── Color Palette ──────────────────────────────────────────
const C = {
  // Skin
  skin:    '#ffcc99',
  skinD:   '#e6b380',
  // Hair
  hairDk:  '#3d2b1f',
  hairMd:  '#5c4033',
  // Clothing
  white:   '#f0f0f0',
  whiteD:  '#d0d0d0',
  red:     '#e63946',
  redD:    '#c1121f',
  blue:    '#457b9d',
  blueD:   '#1d3557',
  green:   '#2a9d8f',
  greenD:  '#1a7a6d',
  yellow:  '#f4a261',
  yellowD: '#e07b39',
  gray:    '#8d99ae',
  grayD:   '#6c757d',
  grayL:   '#adb5bd',
  // Accessories
  glass:   '#a8dadc',
  headph:  '#264653',
  clip:    '#e9c46a',
  // Furniture
  wood:    '#8b6914',
  woodD:   '#6b4f12',
  woodL:   '#a67c00',
  metal:   '#6c757d',
  metalL:  '#adb5bd',
  screen:  '#00ff88',
  screenD: '#005533',
  screenOff: '#2a2a3a',
  black:   '#1a1a2e',
  // Effects
  spark1:  '#ff6b6b',
  spark2:  '#ffd93d',
  smoke:   '#555566',
  zzz:     '#8888cc',
  mail:    '#ffdd57',
  dot_green:  '#00ff88',
  dot_yellow: '#ffd93d',
  dot_red:    '#ff4444',
  dot_blue:   '#4488ff',
  dot_orange: '#ff8800',
  dot_white:  '#cccccc',
};

// ── Helper: create empty grid ──────────────────────────────
function emptyGrid(w, h) {
  return Array.from({length: h}, () => Array(w).fill(null));
}

// ── Helper: paint pixels from a compact string map ─────────
// Each char maps to a color via a legend. '.' = transparent.
function fromMap(lines, legend) {
  return lines.map(row =>
    [...row].map(ch => ch === '.' ? null : (legend[ch] || null))
  );
}

// ── Character Legends ──────────────────────────────────────
const LEG_MANAGER = {
  'H': C.hairDk, 'S': C.skin, 's': C.skinD,
  'W': C.white, 'w': C.whiteD, 'R': C.red, 'r': C.redD,
  'G': C.gray, 'g': C.grayD, 'B': C.black,
};

const LEG_RESEARCHER = {
  'H': C.hairMd, 'S': C.skin, 's': C.skinD,
  'B': C.blue, 'b': C.blueD, 'G': C.glass,
  'g': C.gray, 'K': C.black,
};

const LEG_DEVELOPER = {
  'H': C.hairDk, 'S': C.skin, 's': C.skinD,
  'G': C.green, 'g': C.greenD, 'P': C.headph,
  'K': C.gray, 'k': C.grayD, 'B': C.black,
};

const LEG_MONITORING = {
  'H': C.hairDk, 'S': C.skin, 's': C.skinD,
  'Y': C.yellow, 'y': C.yellowD, 'W': C.white, 'w': C.whiteD,
  'C': C.clip, 'g': C.gray, 'B': C.black,
};

// ── Manager Sprites ────────────────────────────────────────
const MANAGER_WORKING = fromMap([
  // 16 chars wide, 24 rows
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '....SSSSSSSS....',
  '....S.SS.SSS....',
  '....SSSSSSSS....',
  '....SSsSSsSS....',
  '.....SSSSSS.....',
  '......SSSS......',
  '.....WWRWWW.....',
  '....WWWRWWWW....',
  '....WWWRWWWW....',
  '...sWWWWWWWWs...',
  '..ss.WWWWWW.ss..',
  '.ss..WWWWWW..ss.',
  '.s...WWWWWW...s.',
  '.....GWWWWG.....',
  '.....GG..GG.....',
  '.....GG..GG.....',
  '.....GG..GG.....',
  '.....GG..GG.....',
  '.....Gg..gG.....',
  '.....BB..BB.....',
], LEG_MANAGER);

const MANAGER_WORKING2 = fromMap([
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '....SSSSSSSS....',
  '....S.SS.SSS....',
  '....SSSSSSSS....',
  '....SSsSSsSS....',
  '.....SSSSSS.....',
  '......SSSS......',
  '.....WWRWWW.....',
  '....WWWRWWWW....',
  '....WWWRWWWW....',
  '..ssWWWWWWWWss..',
  '.ss..WWWWWW..ss.',
  's....WWWWWW....s',
  '.....WWWWWW.....',
  '.....GWWWWG.....',
  '.....GG..GG.....',
  '.....GG..GG.....',
  '.....GG..GG.....',
  '.....GG..GG.....',
  '.....Gg..gG.....',
  '.....BB..BB.....',
], LEG_MANAGER);

const MANAGER_IDLE = fromMap([
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '....SSSSSSSS....',
  '....S.SS.SSS....',
  '....SSSSSSSS....',
  '....SSSSSSSS....',
  '.....SSSSSS.....',
  '......SSSS......',
  '.....WWRWWW.....',
  '....WWWRWWWW....',
  '....WWWRWWWW....',
  '....WWWWWWWW....',
  '...sWWWWWWWWs...',
  '...s.WWWWWW.s...',
  '.....WWWWWW.....',
  '.....GWWWWG.....',
  '.....GG..GG.....',
  '.....GG..GG.....',
  '.....GG..GG.....',
  '.....GG..GG.....',
  '.....Gg..gG.....',
  '.....BB..BB.....',
], LEG_MANAGER);

const MANAGER_SLEEPING = fromMap([
  '................',
  '................',
  '................',
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '....SSSSSSSS....',
  '....S.SS.SSS....',
  '....SSSSSSSS....',
  '....SSSSSSSS....',
  '.....SSSSSS.....',
  '..sssSWWRWWSsss.',
  '..s..WWWRWWW.s..',
  '.....WWWRWWW....',
  '.....WWWWWWW....',
  '.....WWWWWWW....',
  '.....WWWWWWW....',
  '................',
  '................',
  '.....GG..GG.....',
  '.....GG..GG.....',
  '.....Gg..gG.....',
  '.....BB..BB.....',
], LEG_MANAGER);

// ── Researcher Sprites ─────────────────────────────────────
const RESEARCHER_WORKING = fromMap([
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '...GSSSSSSSG....',
  '...GS.SS.SSG....',
  '....SSSSSSSS....',
  '....SSsSSsSS....',
  '.....SSSSSS.....',
  '......SSSS......',
  '.....BBBBBB.....',
  '....BBBBBBBB....',
  '....BBBBBBBB....',
  '...sBBBBBBBBs...',
  '..ss.BBBBBB.ss..',
  '.ss..BBBBBB..ss.',
  '.s...BBBBBB...s.',
  '.....gBBBBg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gK..Kg.....',
  '.....KK..KK.....',
], LEG_RESEARCHER);

const RESEARCHER_WORKING2 = fromMap([
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '...GSSSSSSSG....',
  '...GS.SS.SSG....',
  '....SSSSSSSS....',
  '....SSsSSsSS....',
  '.....SSSSSS.....',
  '......SSSS......',
  '.....BBBBBB.....',
  '....BBBBBBBB....',
  '....BBBBBBBB....',
  '..ssBBBBBBBBss..',
  '.ss..BBBBBB..ss.',
  's....BBBBBB....s',
  '.....BBBBBB.....',
  '.....gBBBBg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gK..Kg.....',
  '.....KK..KK.....',
], LEG_RESEARCHER);

const RESEARCHER_IDLE = fromMap([
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '...GSSSSSSSG....',
  '...GS.SS.SSG....',
  '....SSSSSSSS....',
  '....SSSSSSSS....',
  '.....SSSSSS.....',
  '......SSSS......',
  '.....BBBBBB.....',
  '....BBBBBBBB....',
  '....BBBBBBBB....',
  '....BBBBBBBB....',
  '...sBBBBBBBBs...',
  '...s.BBBBBB.s...',
  '.....BBBBBB.....',
  '.....gBBBBg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gK..Kg.....',
  '.....KK..KK.....',
], LEG_RESEARCHER);

const RESEARCHER_SLEEPING = fromMap([
  '................',
  '................',
  '................',
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '...GSSSSSSSG....',
  '...GS.SS.SSG....',
  '....SSSSSSSS....',
  '....SSSSSSSS....',
  '.....SSSSSS.....',
  '..sssSBBBBBSsss.',
  '..s..BBBBBBB.s..',
  '.....BBBBBBB....',
  '.....BBBBBBB....',
  '.....BBBBBBB....',
  '.....BBBBBBB....',
  '................',
  '................',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gK..Kg.....',
  '.....KK..KK.....',
], LEG_RESEARCHER);

// ── Developer Sprites ──────────────────────────────────────
const DEVELOPER_WORKING = fromMap([
  '....PP....PP....',
  '....PPPPPPPP....',
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '....SSSSSSSS....',
  '....S.SS.SSS....',
  '....SSSSSSSS....',
  '....SSsSSsSS....',
  '.....SSSSSS.....',
  '......SSSS......',
  '.....GGGGGG.....',
  '....GGGGGGGG....',
  '....GGGGGGGG....',
  '...sGGGGGGGGs...',
  '..ss.GGGGGG.ss..',
  '.ss..GGGGGG..ss.',
  '.s...GGGGGG...s.',
  '.....KGGGKG.....',
  '.....KK..KK.....',
  '.....KK..KK.....',
  '.....Kk..kK.....',
  '.....BB..BB.....',
], LEG_DEVELOPER);

const DEVELOPER_WORKING2 = fromMap([
  '....PP....PP....',
  '....PPPPPPPP....',
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '....SSSSSSSS....',
  '....S.SS.SSS....',
  '....SSSSSSSS....',
  '....SSsSSsSS....',
  '.....SSSSSS.....',
  '......SSSS......',
  '.....GGGGGG.....',
  '....GGGGGGGG....',
  '....GGGGGGGG....',
  '..ssGGGGGGGGss..',
  '.ss..GGGGGG..ss.',
  's....GGGGGG....s',
  '.....GGGGGG.....',
  '.....KGGGKG.....',
  '.....KK..KK.....',
  '.....KK..KK.....',
  '.....Kk..kK.....',
  '.....BB..BB.....',
], LEG_DEVELOPER);

const DEVELOPER_IDLE = fromMap([
  '....PP....PP....',
  '....PPPPPPPP....',
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '....SSSSSSSS....',
  '....S.SS.SSS....',
  '....SSSSSSSS....',
  '....SSSSSSSS....',
  '.....SSSSSS.....',
  '......SSSS......',
  '.....GGGGGG.....',
  '....GGGGGGGG....',
  '....GGGGGGGG....',
  '....GGGGGGGG....',
  '...sGGGGGGGGs...',
  '...s.GGGGGG.s...',
  '.....GGGGGG.....',
  '.....KGGGKG.....',
  '.....KK..KK.....',
  '.....KK..KK.....',
  '.....Kk..kK.....',
  '.....BB..BB.....',
], LEG_DEVELOPER);

const DEVELOPER_SLEEPING = fromMap([
  '................',
  '....PP....PP....',
  '....PPPPPPPP....',
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '....SSSSSSSS....',
  '....S.SS.SSS....',
  '....SSSSSSSS....',
  '....SSSSSSSS....',
  '.....SSSSSS.....',
  '..sssSGGGGGSsss.',
  '..s..GGGGGGG.s..',
  '.....GGGGGGG....',
  '.....GGGGGGG....',
  '.....GGGGGGG....',
  '.....GGGGGGG....',
  '................',
  '................',
  '.....KK..KK.....',
  '.....KK..KK.....',
  '.....Kk..kK.....',
  '.....BB..BB.....',
], LEG_DEVELOPER);

// ── Monitoring Sprites ─────────────────────────────────────
const MONITORING_WORKING = fromMap([
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '....SSSSSSSS....',
  '....S.SS.SSS....',
  '....SSSSSSSS....',
  '....SSsSSsSS....',
  '.....SSSSSS.....',
  '......SSSS......',
  '.....YYWWYY.....',
  '....YYYYYYYY....',
  '....YYYYYYYY....',
  '...sYYYYYYYYs...',
  '..ss.YYYYYY.ss..',
  '.ss..YYYYYY..ss.',
  '.s...YYYYYY...s.',
  '.....gYYYYg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gB..Bg.....',
  '.....BB..BB.....',
], LEG_MONITORING);

const MONITORING_WORKING2 = fromMap([
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '....SSSSSSSS....',
  '....S.SS.SSS....',
  '....SSSSSSSS....',
  '....SSsSSsSS....',
  '.....SSSSSS.....',
  '......SSSS......',
  '.....YYWWYY.....',
  '....YYYYYYYY....',
  '....YYYYYYYY....',
  '..ssYYYYYYYYss..',
  '.ss..YYYYYY..ss.',
  's....YYYYYY....s',
  '.....YYYYYY.....',
  '.....gYYYYg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gB..Bg.....',
  '.....BB..BB.....',
], LEG_MONITORING);

const MONITORING_IDLE = fromMap([
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '....SSSSSSSS....',
  '....S.SS.SSS....',
  '....SSSSSSSS....',
  '....SSSSSSSS....',
  '.....SSSSSS.....',
  '......SSSS......',
  '.....YYWWYY.....',
  '....YYYYYYYY....',
  '....YYYYYYYY....',
  '....YYYYYYYY....',
  '...sYYYYYYYYs...',
  '...s.YYYYYY.s...',
  '.....YYYYYY.....',
  '.....gYYYYg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gB..Bg.....',
  '.....BB..BB.....',
], LEG_MONITORING);

const MONITORING_SLEEPING = fromMap([
  '................',
  '................',
  '................',
  '......HHHH......',
  '.....HHHHHH.....',
  '....HHHHHHHH....',
  '....HSSSSSHH....',
  '....SSSSSSSS....',
  '....S.SS.SSS....',
  '....SSSSSSSS....',
  '....SSSSSSSS....',
  '.....SSSSSS.....',
  '..sssSYYWYYSsss.',
  '..s..YYYYYYY.s..',
  '.....YYYYYYY....',
  '.....YYYYYYY....',
  '.....YYYYYYY....',
  '.....YYYYYYY....',
  '................',
  '................',
  '.....gg..gg.....',
  '.....gg..gg.....',
  '.....gB..Bg.....',
  '.....BB..BB.....',
], LEG_MONITORING);

// ── Furniture Sprites ──────────────────────────────────────
const FURN_LEG = {
  'W': C.wood, 'w': C.woodD, 'L': C.woodL,
  'M': C.metal, 'm': C.metalL,
  'S': C.screen, 's': C.screenD, 'O': C.screenOff,
  'G': C.grayL, 'g': C.gray, 'K': C.black,
};

const DESK = fromMap([
  '................',
  '................',
  '................',
  '................',
  'WWWWWWWWWWWWWWWW',
  'WLLLLLLLLLLLLLwW',
  'WWWWWWWWWWWWWWWW',
  'Ww............wW',
  '.w............w.',
  '.w............w.',
  '.w............w.',
  '.w............w.',
  '.w............w.',
  '.w............w.',
  '.w............w.',
  '.w............w.',
], FURN_LEG);

const MONITOR_ON = fromMap([
  '..MMMMMMMMMMMM..',
  '..MssssssssssM..',
  '..MSSSSSSSSSsM..',
  '..MSSSSSSSSSsM..',
  '..MSSSSSSSSSsM..',
  '..MSSSSSSSSSsM..',
  '..MSSSSSSSSSsM..',
  '..MssssssssssM..',
  '..MMMMMMMMMMMM..',
  '......MMMM......',
  '....MMMMMMMM....',
  '................',
  '................',
  '................',
  '................',
  '................',
], FURN_LEG);

const MONITOR_OFF = fromMap([
  '..MMMMMMMMMMMM..',
  '..MOOOOOOOOOOM..',
  '..MOOOOOOOOOOM..',
  '..MOOOOOOOOOOM..',
  '..MOOOOOOOOOOM..',
  '..MOOOOOOOOOOM..',
  '..MOOOOOOOOOOM..',
  '..MOOOOOOOOOOM..',
  '..MMMMMMMMMMMM..',
  '......MMMM......',
  '....MMMMMMMM....',
  '................',
  '................',
  '................',
  '................',
  '................',
], FURN_LEG);

const CHAIR = fromMap([
  '................',
  '................',
  '................',
  '................',
  '................',
  '....gGGGGGGg....',
  '....gGGGGGGg....',
  '....gGGGGGGg....',
  '....gggggggg....',
  '....g......g....',
  '....g......g....',
  '....g......g....',
  '................',
  '................',
  '................',
  '................',
], FURN_LEG);

const BOOKSHELF = fromMap([
  'WWWWWWWWWWWWWWWW',
  'WbbrrggbbrrggbbW',
  'WrrbbggrrbbggrrW',
  'WWWWWWWWWWWWWWWW',
  'WggrrbbggrrbbggW',
  'WbbggrrbbggrrbbW',
  'WWWWWWWWWWWWWWWW',
  'WrrggbbrrggbbrrW',
  'WggbbrrggbbrrggW',
  'WWWWWWWWWWWWWWWW',
  'WbbrrggbbrrggbbW',
  'WrrbbggrrbbggrrW',
  'WWWWWWWWWWWWWWWW',
  'Ww............wW',
  'Ww............wW',
  'WWWWWWWWWWWWWWWW',
], {
  'W': C.wood, 'w': C.woodD,
  'r': '#c1121f', 'b': '#457b9d', 'g': '#2a9d8f',
});

const SERVER_RACK = fromMap([
  'MMMMMMMMMMMMMMMM',
  'MssSSSSSSSSSSssM',
  'M..SSSSSSSSSS..M',
  'MMMMMMMMMMMMMMMM',
  'MssSSSSSSSSSSssM',
  'M..SSSSSSSSSS..M',
  'MMMMMMMMMMMMMMMM',
  'MssSSSSSSSSSSssM',
  'M..SSSSSSSSSS..M',
  'MMMMMMMMMMMMMMMM',
  'M..............M',
  'M..............M',
  'MMMMMMMMMMMMMMMM',
  'M..............M',
  'M..............M',
  'MMMMMMMMMMMMMMMM',
], {
  'M': C.metal, 'm': C.metalL, 'S': C.screen, 's': '#00aa55',
});

const WHITEBOARD = fromMap([
  'gggggggggggggggg',
  'gWWWWWWWWWWWWWWg',
  'gWWWWWWWWWWWWWWg',
  'gWWWWWWWWWWWWWWg',
  'gWWWWWWWWWWWWWWg',
  'gWWWWWWWWWWWWWWg',
  'gWWWWWWWWWWWWWWg',
  'gWWWWWWWWWWWWWWg',
  'gWWWWWWWWWWWWWWg',
  'gWWWWWWWWWWWWWWg',
  'gggggggggggggggg',
  '................',
  '................',
  '................',
  '................',
  '................',
], { 'g': C.gray, 'W': '#e8e8e8' });

// ── Sprite Registry ────────────────────────────────────────
const SPRITES = {
  characters: {
    manager: {
      working:   MANAGER_WORKING,
      working2:  MANAGER_WORKING2,
      idle:      MANAGER_IDLE,
      sleeping:  MANAGER_SLEEPING,
    },
    researcher: {
      working:   RESEARCHER_WORKING,
      working2:  RESEARCHER_WORKING2,
      idle:      RESEARCHER_IDLE,
      sleeping:  RESEARCHER_SLEEPING,
    },
    developer: {
      working:   DEVELOPER_WORKING,
      working2:  DEVELOPER_WORKING2,
      idle:      DEVELOPER_IDLE,
      sleeping:  DEVELOPER_SLEEPING,
    },
    monitoring: {
      working:   MONITORING_WORKING,
      working2:  MONITORING_WORKING2,
      idle:      MONITORING_IDLE,
      sleeping:  MONITORING_SLEEPING,
    },
  },
  furniture: {
    desk:       DESK,
    monitor_on: MONITOR_ON,
    monitor_off: MONITOR_OFF,
    chair:      CHAIR,
    bookshelf:  BOOKSHELF,
    server_rack: SERVER_RACK,
    whiteboard: WHITEBOARD,
  },
};

// ── Sprite Renderer ────────────────────────────────────────
function drawSprite(ctx, sprite, x, y, scale) {
  scale = scale || SCALE;
  for (let row = 0; row < sprite.length; row++) {
    for (let col = 0; col < sprite[row].length; col++) {
      const color = sprite[row][col];
      if (color) {
        ctx.fillStyle = color;
        ctx.fillRect(x + col * scale, y + row * scale, scale, scale);
      }
    }
  }
}

// Export for office.js
window.SPRITES = SPRITES;
window.SCALE = SCALE;
window.CHAR_W = CHAR_W;
window.CHAR_H = CHAR_H;
window.FURN_W = FURN_W;
window.FURN_H = FURN_H;
window.drawSprite = drawSprite;
window.COLORS = C;
