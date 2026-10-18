import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
export default defineConfig({ base: './', plugins: [svelte(),{
 name:'thrusters-browser-lab',transformIndexHtml(html,ctx){return ctx.server?html.replace(/<link[^>]+cfx-nui-cortex-lib[^>]*>/g,'').replace(/<script[^>]+cfx-nui-cortex-lib[^>]*><\/script>/g,''):html;}
}], build: { target: 'chrome100' } });
