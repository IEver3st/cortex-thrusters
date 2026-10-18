export type Result<T = unknown> = { ok: true; data?: T } | { ok: false; error: { code: string; message?: string } };
declare global { interface Window { GetParentResourceName?: () => string; CortexUI?: { registerSurface(options: { id: string; selector: string; fixed: boolean; priority: number }): () => void }; thrustersLab?: (scene: string) => void } }
export const isNui = () => typeof window.GetParentResourceName === 'function';
export async function request<T>(action: string, data: unknown = {}): Promise<Result<T>> {
  if (!isNui()) return { ok: false, error: { code: 'LAB_ONLY' } };
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), 4000);
  try {
    const response = await fetch(`https://${window.GetParentResourceName!()}/${action}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data), signal: controller.signal });
    if (!response.ok) throw new Error('transport');
    return await response.json() as Result<T>;
  } catch { return { ok: false, error: { code: 'UNKNOWN_OUTCOME' } }; }
  finally { window.clearTimeout(timer); }
}
// Lua may register its callback after the page loads: retry every 500 ms for up to 20 s.
export async function handshake(action: string): Promise<boolean> {
  for (let i = 0; i < 40; i++) {
    const result = await request(action);
    if (result.ok) return true;
    if (!isNui()) return false;
    await new Promise(resolve => window.setTimeout(resolve, 500));
  }
  return false;
}
export function subscribe(receive: (message: unknown) => void): () => void {
  const listener = (event: MessageEvent<unknown>) => receive(event.data);
  window.addEventListener('message', listener);
  return () => window.removeEventListener('message', listener);
}
export function surface(): () => void {
  return window.CortexUI?.registerSurface({ id: 'thrusters', selector: '.gauge', fixed: true, priority: 100 }) ?? (() => {});
}
