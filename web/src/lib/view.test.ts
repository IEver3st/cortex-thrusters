import {describe,expect,test} from 'bun:test';
import {blank,read,readWords,levelAt,cells,readAttitude,signed} from './view';

describe('read',()=>{
 test('accepts a full snapshot',()=>{
  const v=read({action:'thrusters:state',data:{visible:true,state:'locked',live:false,grip:'hold',level:12.5,capacity:100,rate:9,wait:1500,lockout:30,low:25,anchor:{right:52,bottom:240,width:200}}});
  expect(v).not.toBeNull();
  expect(v!.state).toBe('locked');
  expect(v!.grip).toBe('hold');
  expect(v!.anchor).toEqual({right:52,bottom:240,width:200});
 });
 test('takes the grip cooldown and drops the old minimap anchor',()=>{
  const v=read({action:'thrusters:state',data:{visible:true,grip:'cool',anchor:{left:.02,top:.8,width:.14}}})!;
  expect(v.grip).toBe('cool');
  expect(v.anchor).toEqual(blank.anchor);
 });
 test('rejects other actions and a non-boolean visible',()=>{
  expect(read({action:'other',data:{visible:true}})).toBeNull();
  expect(read({action:'thrusters:state',data:{visible:'yes'}})).toBeNull();
 });
 test('falls back on bad fields instead of rendering them',()=>{
  const v=read({action:'thrusters:state',data:{visible:true,state:'boom',grip:5,level:Infinity,rate:NaN,anchor:{right:-1,bottom:200,width:176}}})!;
  expect(v.state).toBe('ready');
  expect(v.grip).toBe('off');
  expect(v.level).toBe(v.capacity);
  expect(v.rate).toBe(0);
  expect(v.anchor).toEqual(blank.anchor);
 });
});

describe('levelAt',()=>{
 const base={...blank,visible:true};
 test('drains at once and stops at empty',()=>{
  const v={...base,level:50,rate:-20,wait:0};
  expect(levelAt(v,1000)).toBe(30);
  expect(levelAt(v,10000)).toBe(0);
 });
 test('refills only after the wait and stops at full',()=>{
  const v={...base,level:40,rate:10,wait:2000};
  expect(levelAt(v,1500)).toBe(40);
  expect(levelAt(v,3000)).toBe(50);
  expect(levelAt(v,60000)).toBe(100);
 });
});

test('cells split the level into ten tenths',()=>{
 expect(cells(35,100)).toEqual([1,1,1,.5,0,0,0,0,0,0].map((n,i)=>i===3?expect.closeTo(.5,5):n));
 expect(cells(100,100).every(n=>n===1)).toBe(true);
});

test('words fall back when missing or too long',()=>{
 const w=readWords({action:'thrusters:text',data:{label:'Kaltgas',locked:'x'.repeat(40)}})!;
 expect(w.label).toBe('Kaltgas');
 expect(w.locked).toBe('Refilling');
 expect(w.grip).toBe('Grip');
});

describe('readAttitude',()=>{
 test('takes both tags',()=>{
  const a=readAttitude({action:'thrusters:attitude',data:{visible:true,roll:{on:true,x:.62,y:.44,deg:-12.4,rate:180},yaw:{on:true,x:.5,y:.3,deg:274,delta:8.2,rate:-40}}})!;
  expect(a.visible).toBe(true);
  expect(a.roll).toEqual({on:true,x:.62,y:.44,deg:-12.4,rate:180});
  expect(a.yaw.delta).toBe(8.2);
 });
 test('hides a tag that is off screen or malformed',()=>{
  const a=readAttitude({action:'thrusters:attitude',data:{visible:true,roll:{on:false,x:.5,y:.5,deg:0},yaw:{on:true,x:'mid',y:.5,deg:10}}})!;
  expect(a.roll.on).toBe(false);
  expect(a.yaw.on).toBe(false);
 });
 test('rejects out of range angles, other actions and a non-boolean visible',()=>{
  expect(readAttitude({action:'thrusters:attitude',data:{visible:true,roll:{on:true,x:.5,y:.5,deg:400}}})!.roll.on).toBe(false);
  expect(readAttitude({action:'thrusters:state',data:{visible:true}})).toBeNull();
  expect(readAttitude({action:'thrusters:attitude',data:{visible:1}})).toBeNull();
 });
 test('hidden is hidden',()=>{
  expect(readAttitude({action:'thrusters:attitude',data:{visible:false}})!.visible).toBe(false);
 });
});

describe('signed',()=>{
 test('whole degrees with a real minus',()=>{
  expect(signed(12.4)).toBe('+12°');
  expect(signed(-3.6)).toBe('−4°');
  expect(signed(0.3)).toBe('0°');
 });
});
