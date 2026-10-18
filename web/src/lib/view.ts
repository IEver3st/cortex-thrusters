export type Tank = 'ready' | 'low' | 'locked';
export type Grip = 'off' | 'hold' | 'search' | 'cool';
export interface View {
 visible: boolean; state: Tank; live: boolean; grip: Grip;
 level: number; capacity: number; rate: number; wait: number; lockout: number; low: number;
// Bottom-right placement in 1080p units (`--u`), above the speedometer.
 anchor: { right: number; bottom: number; width: number };
}
export interface Words { label: string; locked: string; grip: string }

export const blank: View = { visible: false, state: 'ready', live: false, grip: 'off', level: 100, capacity: 100, rate: 0, wait: 0,
 lockout: 30, low: 25, anchor: { right: 40, bottom: 200, width: 176 } };
export const defaultWords: Words = { label: 'Cold gas', locked: 'Refilling', grip: 'Grip' };

const obj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const num = (v: unknown, min: number, max: number): number | null => typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max ? v : null;
const text = (v: unknown, fallback: string) => typeof v === 'string' && v.length > 0 && v.length <= 24 && !/[\u0000-\u001f\u007f]/.test(v) ? v : fallback;

export function read(message: unknown): View | null {
 if (!obj(message) || message.action !== 'thrusters:state' || !obj(message.data) || typeof message.data.visible !== 'boolean') return null;
 const d = message.data;
 const capacity = num(d.capacity, 1, 10000) ?? 100;
 const v: View = { ...blank, visible: d.visible === true, capacity };
 v.state = d.state === 'low' || d.state === 'locked' ? d.state : 'ready';
 v.grip = d.grip === 'hold' || d.grip === 'search' || d.grip === 'cool' ? d.grip : 'off';
 v.live = d.live === true;
 v.level = num(d.level, 0, capacity) ?? capacity;
 v.rate = num(d.rate, -10000, 10000) ?? 0;
 v.wait = num(d.wait, 0, 600000) ?? 0;
 v.lockout = num(d.lockout, 0, capacity) ?? blank.lockout;
 v.low = num(d.low, 0, capacity) ?? blank.low;
 if (obj(d.anchor)) {
  const right = num(d.anchor.right, 0, 1800), bottom = num(d.anchor.bottom, 0, 1000), width = num(d.anchor.width, 60, 600);
  if (right !== null && bottom !== null && width !== null) v.anchor = { right, bottom, width };
 }
 return v;
}

export function readWords(message: unknown): Words | null {
 if (!obj(message) || message.action !== 'thrusters:text' || !obj(message.data)) return null;
 const d = message.data;
 return { label: text(d.label, defaultWords.label), locked: text(d.locked, defaultWords.locked), grip: text(d.grip, defaultWords.grip) };
}

// Level `elapsed` ms after the snapshot: the rate starts after `wait` and the
// tank never leaves 0..capacity. Lua sends a new snapshot on every change.
export function levelAt(v: View, elapsed: number): number {
 const running = Math.max(0, elapsed - (v.rate > 0 ? v.wait : 0));
 return Math.min(v.capacity, Math.max(0, v.level + v.rate * running / 1000));
}

// Ten cells of ten percent: how full each one is (0..1).
export function cells(level: number, capacity: number, count = 10): number[] {
 const filled = level / capacity * count;
 return Array.from({ length: count }, (_, i) => Math.min(1, Math.max(0, filled - i)));
}
