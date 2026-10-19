<script lang="ts">
import {onMount} from 'svelte';
import {blank,defaultWords,read,readWords,levelAt,cells,readAttitude,noAttitude,signed,type View,type Words,type Attitude} from './lib/view';
import {subscribe,surface,handshake} from './lib/bridge';

// The cold gas gauge: a slip tag (COLD GAS | 82) over ten cells, sitting on
// the speedometer at its width (bottom-right, 1080p units). Lua sends a snapshot on every change;
// between snapshots the page runs the drain or refill itself.
let v=$state<View>({...blank});
let words=$state<Words>({...defaultWords});
let level=$state(blank.level);
// Debug attitude overlay: two tags riding on the rings Lua draws round the car.
let attitude=$state<Attitude>({...noAttitude});
let received=0, frame=0;

function tick(){
 frame=0;
 level=levelAt(v,performance.now()-received);
 const settled=v.rate===0||(v.rate>0&&level>=v.capacity)||(v.rate<0&&level<=0);
 if(v.visible&&!settled)frame=requestAnimationFrame(tick);
}
function restart(){
 if(frame)cancelAnimationFrame(frame);
 frame=0;
 tick();
}

onMount(()=>{
 const unsubscribe=subscribe(message=>{
  const pose=readAttitude(message);
  if(pose){attitude=pose;return;}
  const next=read(message);
  if(next){v=next;received=performance.now();restart();return;}
  const text=readWords(message);
  if(text)words=text;
 });
 const release=surface();
 void handshake('ready');
 return ()=>{unsubscribe();release();if(frame)cancelAnimationFrame(frame);};
});

const percent=$derived(Math.round(level/v.capacity*100));
const locked=$derived(v.state==='locked');
const low=$derived(v.state==='low');
const meter=$derived(cells(level,v.capacity));
const rate=(n:number)=>`${signed(n)}/s`;
</script>
{#if v.visible}
 <aside class="gauge" aria-label={words.label}
  style:right={`calc(${v.anchor.right} * var(--u))`} style:bottom={`calc(${v.anchor.bottom} * var(--u))`} style:min-width={`calc(${v.anchor.width} * var(--u))`}>
  <div class="row">
   <div class="tag">
    <span class="key" class:live={v.live&&!locked} class:low={low&&!v.live} class:locked>
     <!-- Both labels share one cell, so the tag never changes width. -->
     {#each [words.label,words.locked] as text}<b class:shown={text===(locked?words.locked:words.label)}>{text}</b>{/each}
    </span>
    <span class="value">{percent}</span>
   </div>
   {#if v.grip!=='off'}<span class="chip" class:search={v.grip==='search'} class:cool={v.grip==='cool'}>{words.grip}</span>{/if}
  </div>
  <div class="meter" class:live={v.live&&!locked} class:low class:locked>
   {#each meter as fill}<i><b style:transform={`scaleX(${fill})`}></b></i>{/each}
   {#if locked}<em style:left={v.lockout/v.capacity*100+'%'}></em>{/if}
  </div>
 </aside>
{/if}
{#if attitude.visible}
 {#if attitude.roll.on}
  <div class="pose" style:left={attitude.roll.x*100+'%'} style:top={attitude.roll.y*100+'%'}>
   <div class="tag"><span class="key live">Roll</span><span class="value">{signed(attitude.roll.deg)}</span></div>
   <span class="rate">{rate(attitude.roll.rate)}</span>
  </div>
 {/if}
 {#if attitude.yaw.on}
  <div class="pose" style:left={attitude.yaw.x*100+'%'} style:top={attitude.yaw.y*100+'%'}>
   <div class="tag"><span class="key live">Yaw</span><span class="value">{Math.round(attitude.yaw.deg)%360}°</span></div>
   <span class="rate">Δ {signed(attitude.yaw.delta)} · {rate(attitude.yaw.rate)}</span>
  </div>
 {/if}
{/if}
