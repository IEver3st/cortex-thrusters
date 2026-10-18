import { mount } from 'svelte';
import App from './App.svelte';
import './cortex.css';
import './style.css';
if (import.meta.env.DEV) await import('./dev/lab');
mount(App, { target: document.getElementById('app')! });

