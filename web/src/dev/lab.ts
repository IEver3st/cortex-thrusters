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
// Attitude scenes: a stand-in car seen from behind with the rings Lua would draw,
// and the tags where it would project them (0..1 of the screen).
const poses:Record<string,{bank:number,heading:number,delta:number,rollRate:number,yawRate:number,cx:number,cy:number}>={
 attitude:{bank:-4,heading:274,delta:3,rollRate:-12,yawRate:8,cx:.5,cy:.55},
 'attitude-rolled':{bank:38,heading:121,delta:-87,rollRate:184,yawRate:-142,cx:.48,cy:.5},
 'attitude-edge':{bank:-162,heading:9,delta:178,rollRate:-360,yawRate:96,cx:.86,cy:.2},
};
let pose:typeof poses[string]|null=null;
function attitude(scene:string){
 const p=poses[scene];pose=p??null;background();
 if(!p){window.dispatchEvent(new MessageEvent('message',{data:{action:'thrusters:attitude',data:{visible:false}}}));return;}
 const a=-p.bank*Math.PI/180,r=ringRadius();
 // Lua puts the roll tag past the horizon tick on the car's right-hand side.
 const side=Math.cos(a)>=0?1:-1;
 const roll={on:true,x:p.cx+side*(r+.07*innerHeight)/innerWidth,y:p.cy,deg:p.bank,rate:p.rollRate};
 const yaw={on:true,x:p.cx,y:p.cy+(r*.35+.09*innerHeight)/innerHeight,deg:p.heading,delta:p.delta,rate:p.yawRate};
 window.dispatchEvent(new MessageEvent('message',{data:{action:'thrusters:attitude',data:{visible:true,roll,yaw}}}));
}
function ringRadius(){return Math.min(innerWidth,innerHeight)*.17;}
window.thrustersLab=(scene:string)=>{
 if(scene.startsWith('attitude')){attitude(scene);return;}
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
 if(pose)rings(ctx,color,u);
}
// The car's silhouette (from behind) and the two rings, drawn like the in-world
// strokes: paper with an ink edge, accent ticks and a faint accent wedge.
function rings(ctx:CanvasRenderingContext2D,color:(name:string)=>string,u:number){
 const p=pose!,cx=p.cx*world.width,cy=p.cy*world.height,r=ringRadius(),a=-p.bank*Math.PI/180;
 const accent=getComputedStyle(document.body).getPropertyValue('--accent').trim()||color('--paper');
 const line=(w:number,c:string,draw:()=>void)=>{ctx.lineCap='round';ctx.strokeStyle=color('--ink');ctx.lineWidth=(w+2)*u;ctx.beginPath();draw();ctx.stroke();ctx.strokeStyle=c;ctx.lineWidth=w*u;ctx.beginPath();draw();ctx.stroke();};
 ctx.save();ctx.translate(cx,cy);
 // Yaw ring: flat, seen in perspective.
 ctx.save();ctx.scale(1,.35);ctx.globalAlpha=.85;line(4,color('--paper'),()=>ctx.arc(0,0,r*1.25,0,Math.PI*2));ctx.restore();
 const ya=(p.delta)*Math.PI/180;
 ctx.save();ctx.scale(1,.35);ctx.fillStyle=accent;ctx.globalAlpha=.27;ctx.beginPath();ctx.moveTo(0,0);ctx.arc(0,0,r*1.25,Math.PI/2-ya,Math.PI/2,ya<0);ctx.closePath();ctx.fill();ctx.restore();
 line(6,accent,()=>{ctx.moveTo(0,r*.35*1.25-12*u);ctx.lineTo(0,r*.35*1.25+12*u);});
 // Car body from behind, banked.
 ctx.save();ctx.rotate(a);ctx.fillStyle=color('--slip');ctx.fillRect(-r*.62,-r*.28,r*1.24,r*.5);ctx.fillStyle=color('--ink');ctx.fillRect(-r*.5,r*.22,r*.26,r*.16);ctx.fillRect(r*.24,r*.22,r*.26,r*.16);ctx.restore();
 // Roll ring, horizon ticks, bank wedge, accent ticks on the car's sides.
 line(4,color('--paper'),()=>ctx.arc(0,0,r,0,Math.PI*2));
 ctx.fillStyle=accent;ctx.globalAlpha=.27;ctx.beginPath();ctx.moveTo(0,0);ctx.arc(0,0,r,0,a,a<0);ctx.closePath();ctx.fill();ctx.globalAlpha=1;
 for(const s of [1,-1])line(4,color('--paper'),()=>{ctx.moveTo(s*(r-12*u),0);ctx.lineTo(s*(r+40*u),0);});
 for(const t of [0,Math.PI,-Math.PI/2])line(6,accent,()=>{ctx.moveTo(Math.cos(a+t)*(r-20*u),Math.sin(a+t)*(r-20*u));ctx.lineTo(Math.cos(a+t)*(r+20*u),Math.sin(a+t)*(r+20*u));});
 ctx.restore();
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
