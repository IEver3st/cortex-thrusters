// Browser lab: named scenes for review. Vite drops this from production builds.
// ?scene=<name>&background=dark|sky|street&accent=blue|paper&zoom=3&reduced=1
import {blank} from '../lib/view';
const parameters=new URLSearchParams(location.search);
const anchor={right:40,bottom:200,width:176};
function state(scene:string){
 const value:Record<string,unknown>={...blank,visible:true,anchor,level:100,rate:0,wait:0,state:'ready',live:false,grip:'off'};
 if(scene==='hidden')value.visible=false;
 if(scene==='boost')Object.assign(value,{level:72,rate:-15,live:true});
 if(scene==='hover')Object.assign(value,{level:58,rate:-24,live:true});
 if(scene==='refill')Object.assign(value,{level:41,rate:9,wait:1800});
 if(scene==='low')Object.assign(value,{level:18,state:'low',rate:9});
 if(scene==='locked')Object.assign(value,{level:6,state:'locked',rate:9});
 if(scene==='grip')Object.assign(value,{level:83,rate:-3.5,grip:'hold'});
 if(scene==='grip-search')Object.assign(value,{level:83,rate:0,grip:'search'});
 if(scene==='grip-cool')Object.assign(value,{level:83,rate:0,grip:'cool'});
 if(scene==='grip-live')Object.assign(value,{level:64,rate:-27.5,grip:'hold',live:true});
 if(scene==='empty')Object.assign(value,{level:0,state:'locked',rate:0});
 return value;
}
window.thrustersLab=(scene:string)=>{
 if(scene==='malformed'){window.dispatchEvent(new MessageEvent('message',{data:{action:'thrusters:state',data:{visible:'yes',level:Infinity}}}));return;}
 if(scene==='long-words')window.dispatchEvent(new MessageEvent('message',{data:{action:'thrusters:text',data:{label:'Kaltgas',locked:'Wird gefüllt',grip:'Haftung'}}}));
 window.dispatchEvent(new MessageEvent('message',{data:{action:'thrusters:state',data:state(scene==='long-words'?'locked':scene)}}));
};
const world=document.createElement('canvas');world.setAttribute('aria-hidden','true');
Object.assign(world.style,{position:'fixed',inset:'0',width:'100%',height:'100%',pointerEvents:'none',zIndex:'-1'});
document.body.prepend(world);
function background(){
 world.width=window.innerWidth;world.height=window.innerHeight;
 const ctx=world.getContext('2d')!;const tokens=getComputedStyle(document.documentElement);
 const color=(name:string)=>tokens.getPropertyValue(name).trim();const bg=parameters.get('background')??'dark';
 ctx.fillStyle=color(bg==='sky'?'--paper':bg==='street'?'--dim':'--ink');ctx.fillRect(0,0,world.width,world.height);
 if(bg==='street'){ctx.save();ctx.translate(world.width*.6,world.height*.65);ctx.rotate(-.3);
 ctx.fillStyle=color('--ink');ctx.fillRect(-world.width*.3,-world.height*.3,world.width*.8,world.height*.8);
 ctx.fillStyle=color('--muted');ctx.fillRect(-world.width*.3+40,-world.height*.3+40,world.width*.8-80,world.height*.8-80);ctx.restore();}
 // Stand-in Cortex HUD speedometer (bottom-right, 40 in, 64 up, 176 wide) under the gauge.
 const probe=document.createElement('i');probe.style.cssText='position:fixed;width:calc(1000 * var(--u))';document.body.append(probe);
 const u=probe.getBoundingClientRect().width/1000;probe.remove();
 ctx.fillStyle=color('--dim');
 ctx.fillRect(world.width-(anchor.right+anchor.width)*u,world.height-(64+112)*u,anchor.width*u,112*u);
}
window.addEventListener('resize',background);background();
const style=document.createElement('style');
style.textContent=`html[data-lab-reduced] *,html[data-lab-reduced] *::before,html[data-lab-reduced] *::after{animation:none!important;transition:none!important;}`;
document.head.append(style);
if(parameters.get('accent')==='blue')document.documentElement.style.setProperty('--cx-accent','var(--info)');
if(parameters.get('accent')==='paper')document.documentElement.style.setProperty('--cx-accent','var(--paper)');
if(parameters.get('zoom')==='3')document.documentElement.style.setProperty('--u','max(2.16px, 0.2777777778vmin)');
if(parameters.get('reduced')==='1')document.documentElement.dataset.labReduced='';
window.setTimeout(()=>window.thrustersLab?.(parameters.get('scene')??'boost'),150);
