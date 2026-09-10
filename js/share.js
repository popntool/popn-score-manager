import{popClassSelection,songPopClass}from"./scores.js?v=3.0.40";
import{medalInfo}from"./ui.js?v=3.0.37";

const HASHTAG="#popn_score_manager",SHARE_TEXT=`${HASHTAG}\n`,BG="#fffaf0",PANEL="#fffdf6",INK="#142b67",MUTED="#69789d",LINE="#3153a0",ACCENT="#ffd851",BLUE="#68bdf0";
const TARGET_BYTES=1024*1024;
const FONT='system-ui,-apple-system,"Segoe UI","Noto Sans JP",sans-serif';
const imgCache=new Map();
const escFile=v=>String(v||"player").replace(/[\\/:*?"<>|\s]+/g,"_").slice(0,60)||"player";
const chartOrder={EX:0,HYPER:1,NORMAL:2,LIGHT:3};

function rounded(ctx,x,y,w,h,r=18,fill=PANEL,stroke=LINE,lw=3){ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fillStyle=fill;ctx.fill();if(stroke){ctx.lineWidth=lw;ctx.strokeStyle=stroke;ctx.stroke();}}
function text(ctx,value,x,y,size=28,weight=700,color=INK,align="left",baseline="middle"){ctx.font=`${weight} ${size}px ${FONT}`;ctx.fillStyle=color;ctx.textAlign=align;ctx.textBaseline=baseline;ctx.fillText(String(value??""),x,y);}
function fitText(ctx,value,maxWidth,size=25,weight=800){let s=size;while(s>15){ctx.font=`${weight} ${s}px ${FONT}`;if(ctx.measureText(String(value)).width<=maxWidth)return s;s--;}return s;}
function ellipsize(ctx,value,maxWidth,size=20,weight=800){const raw=String(value??"");ctx.font=`${weight} ${size}px ${FONT}`;if(ctx.measureText(raw).width<=maxWidth)return raw;let out=raw;while(out&&ctx.measureText(out+"…").width>maxWidth)out=out.slice(0,-1);return out?out+"…":"…";}
async function fetchBitmap(url){const response=await fetch(url,{mode:"cors",cache:"force-cache"});if(!response.ok)throw new Error(String(response.status));const blob=await response.blob();return await createImageBitmap(blob);}
async function loadImage(url){if(!url)return null;if(imgCache.has(url))return imgCache.get(url);const promise=(async()=>{try{return await fetchBitmap(url);}catch{try{const parsed=new URL(url,location.href);if(parsed.origin===location.origin)return null;return await fetchBitmap(`https://wsrv.nl/?url=${encodeURIComponent(parsed.href)}&output=png`);}catch{return null;}}})();imgCache.set(url,promise);return promise;}
function contain(ctx,img,x,y,w,h){if(!img)return false;const scale=Math.min(w/img.width,h/img.height),dw=img.width*scale,dh=img.height*scale;ctx.drawImage(img,x+(w-dw)/2,y+(h-dh)/2,dw,dh);return true;}
function effectiveMedal(row){return Number(row.score)===100000?{label:"COOL PERFECT",url:"./assets/cool-perfect.png"}:medalInfo(row.medal_code);}
function medalFallback(ctx,label,x,y,size){ctx.save();ctx.translate(x+size/2,y+size/2);ctx.rotate(Math.PI/4);rounded(ctx,-size*.31,-size*.31,size*.62,size*.62,8,"#f5e8ad",LINE,3);ctx.restore();text(ctx,label==="－　未プレー"?"－":label.slice(0,2),x+size/2,y+size/2,15,900,INK,"center");}
async function drawMedal(ctx,row,x,y,size){const info=effectiveMedal(row);if(String(row.medal_code||"none").toLowerCase()==="none"&&Number(row.score)!==100000){text(ctx,"－",x+size/2,y+size/2,26,700,MUTED,"center");return;}const img=await loadImage(info.url);if(!contain(ctx,img,x,y,size,size))medalFallback(ctx,info.label,x,y,size);}
async function drawBanner(ctx,row,x,y,w,h){rounded(ctx,x,y,w,h,8,"#f5f0df",null,0);const img=await loadImage(row.banner_url);if(!contain(ctx,img,x,y,w,h)){text(ctx,"NO IMAGE",x+w/2,y+h/2,18,800,MUTED,"center");}ctx.lineWidth=1;ctx.strokeStyle=LINE;ctx.strokeRect(x,y,w,h);}
function header(ctx,title,subtitle,username,width){ctx.fillStyle=ACCENT;ctx.fillRect(0,0,width,84);text(ctx,"♪",32,42,30,900,"#fff","center");ctx.beginPath();ctx.arc(32,42,23,0,Math.PI*2);ctx.lineWidth=4;ctx.strokeStyle=INK;ctx.stroke();text(ctx,"pop'n Score Manager",62,33,22,900,INK);text(ctx,username||"PLAYER",62,59,14,700,MUTED);text(ctx,title,width-28,32,25,900,INK,"right");text(ctx,subtitle,width-28,59,14,700,MUTED,"right");}
function footer(ctx,width,height){text(ctx,HASHTAG,width-36,height-30,18,800,MUTED,"right");}
async function preload(rows){const urls=new Set(["./assets/cool-perfect.png"]);for(const row of rows){if(row.banner_url)urls.add(row.banner_url);const m=effectiveMedal(row);if(m.url)urls.add(m.url);}const list=[...urls];let i=0;await Promise.all(Array.from({length:Math.min(12,list.length)},async()=>{while(i<list.length){const url=list[i++];await loadImage(url);}}));}
function canvas(width,height){const c=document.createElement("canvas");c.width=width;c.height=height;const ctx=c.getContext("2d");ctx.fillStyle=BG;ctx.fillRect(0,0,width,height);return[c,ctx];}
async function blobFromCanvas(c){
 let quality=.86,blob=null;
 for(let i=0;i<5;i++){
  blob=await new Promise((resolve,reject)=>c.toBlob(b=>b?resolve(b):reject(new Error("画像を作成できませんでした。")),"image/jpeg",quality));
  if(blob.size<=TARGET_BYTES||quality<=.58)break;
  quality-=.07;
 }
 return blob;
}
async function shareBlob(blob,filename,title){const file=new File([blob],filename,{type:"image/jpeg"}),data={files:[file],title,text:SHARE_TEXT};if(navigator.share&&(!navigator.canShare||navigator.canShare({files:[file]}))){try{await navigator.share(data);return"shared";}catch(error){if(error?.name==="AbortError")return"cancelled";}}
const url=URL.createObjectURL(blob),a=document.createElement("a");a.href=url;a.download=filename;document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);return"downloaded";}

const CHART_STYLE={EX:["#ef426f","#fff"],HYPER:["#fff2a6","#7b6500"],NORMAL:["#bdf39a","#17652b"],LIGHT:["#c8e3ff","#24558d"]};
function chartBadge(ctx,chart,level,x,y){const [bg,fg]=CHART_STYLE[chart]||["#eef1f7",INK];rounded(ctx,x,y,68,25,5,bg,null,0);text(ctx,`${chart} ${level}`,x+34,y+13,13,900,fg,"center");}
async function drawScoreTile(ctx,row,x,y,w,h){
 rounded(ctx,x,y,w,h,10,PANEL,LINE,2);
 await drawBanner(ctx,row,x+7,y+7,118,43);
 await drawMedal(ctx,row,x+132,y+7,40);
 const contentX=x+180,metricW=100,titleW=Math.max(70,w-(contentX-x)-metricW-8);
 text(ctx,ellipsize(ctx,row.title,titleW,15,900),contentX,y+17,15,900,INK);
 chartBadge(ctx,row.chart,row.level,contentX,y+31);
 text(ctx,`スコア ${String(Number(row.version_score||0)).padStart(5,"0")}`,x+w-8,y+17,12,800,INK,"right");
 text(ctx,`ポックラ ${songPopClass(row).toFixed(2)}`,x+w-8,y+43,12,900,INK,"right");
}
function sectionTitle(ctx,label,count,x,y,w){text(ctx,label,x,y+18,21,900,INK);text(ctx,`${count}曲`,x+w,y+18,14,800,MUTED,"right");ctx.fillStyle=LINE;ctx.fillRect(x,y+35,w,2);}
export async function sharePopClassImage(rows,username){const {current,other,total}=popClassSelection(rows),all=[...current,...other];if(!all.length)throw new Error("ポックラ対象曲がありません。");await preload(all);const width=900,pad=22,gap=8,tileW=(width-pad*2-gap)/2,tileH=58;const curRows=Math.ceil(current.length/2),otherRows=Math.ceil(other.length/2),height=84+48+curRows*(tileH+gap)+48+otherRows*(tileH+gap)+42;const[c,ctx]=canvas(width,height);header(ctx,"ポックラ対象一覧",`TOTAL ${total.toFixed(2)}`,username,width);ctx.save();ctx.scale(.75,.75);ctx.restore();let y=96;sectionTitle(ctx,"今作 TOP 20",current.length,pad,y,width-pad*2);y+=42;for(let i=0;i<current.length;i++){const col=i%2,row=Math.floor(i/2);await drawScoreTile(ctx,current[i],pad+col*(tileW+gap),y+row*(tileH+gap),tileW,tileH);}y+=curRows*(tileH+gap)+2;sectionTitle(ctx,"その他 TOP 40",other.length,pad,y,width-pad*2);y+=42;for(let i=0;i<other.length;i++){const col=i%2,row=Math.floor(i/2);await drawScoreTile(ctx,other[i],pad+col*(tileW+gap),y+row*(tileH+gap),tileW,tileH);}footer(ctx,width,height);const blob=await blobFromCanvas(c);return shareBlob(blob,`popn_popclass_${escFile(username)}.jpg`,"pop'n Score Manager ポックラ対象一覧");}

async function drawLevelTile(ctx,row,x,y,w,h){
 rounded(ctx,x,y,w,h,8,PANEL,LINE,2);
 const medalSize=Math.min(42,Math.max(28,h-10));
 const medalW=medalSize+12;
 await drawBanner(ctx,row,x+6,y+6,w-medalW-18,h-12);
 await drawMedal(ctx,row,x+w-medalW+1,y+(h-medalSize)/2,medalSize);
}

const MEDAL_GROUPS=[
 ["perfect",["perfect","a"]],["fc_1_5",["fc_1_5","b"]],["fc_6_20",["fc_6_20","c"]],["fc_21_plus",["fc_21_plus","d"]],
 ["clear_bad_1_5",["clear_bad_1_5","e"]],["clear_bad_6_20",["clear_bad_6_20","f"]],["clear_bad_21_plus",["clear_bad_21_plus","g"]],
 ["long_off",["long_off"]],["easy",["easy","k"]],["failed_15_16",["failed_15_16","h","l"]],["failed_12_14",["failed_12_14","i","m"]],["failed_0_11",["failed_0_11","j","n"]],["none",["none"]]
];
function medalOrder(code){const normalized=String(code||"none").toLowerCase(),index=MEDAL_GROUPS.findIndex(([,codes])=>codes.includes(normalized));return index<0?MEDAL_GROUPS.length:index;}
function medalShareSort(a,b){
 const value=row=>Number(row.score)===100000?-1:medalOrder(row.medal_code);
 return value(a)-value(b)
  ||Number(b.level||0)-Number(a.level||0)
  ||Number(b.version_score||0)-Number(a.version_score||0)
  ||Number(b.score||0)-Number(a.score||0)
  ||songPopClass(b)-songPopClass(a)
  ||String(a.title||"").localeCompare(String(b.title||""),"ja")
  ||(chartOrder[a.chart]??9)-(chartOrder[b.chart]??9);
}
function gridForCount(count){
 const candidates=[];
 for(let cols=3;cols<=8;cols++){
  const rows=Math.ceil(count/cols),ratio=cols/Math.max(rows,1);
  const target=1.45;
  const score=Math.abs(Math.log(ratio/target))+(rows>8?(rows-8)*.18:0)+(cols>6?(cols-6)*.06:0);
  candidates.push({cols,rows,score});
 }
 return candidates.sort((a,b)=>a.score-b.score)[0];
}
async function drawMedalLegend(ctx,rows,x,y,w){
 const ordered=[];
 for(const row of rows){
  const info=effectiveMedal(row),key=Number(row.score)===100000?"cool-perfect":String(row.medal_code||"none").toLowerCase();
  if(!ordered.some(item=>item.key===key))ordered.push({key,info,row});
 }
 ordered.sort((a,b)=>{const av=a.key==="cool-perfect"?-1:medalOrder(a.key),bv=b.key==="cool-perfect"?-1:medalOrder(b.key);return av-bv;});
 const items=ordered.slice(0,15),cellW=w/Math.max(items.length,1);
 for(let i=0;i<items.length;i++){
  const cx=x+i*cellW;
  await drawMedal(ctx,items[i].row,cx+(cellW-28)/2,y,28);
 }
}
export async function shareLevelMedalImage(rows,level,username){
 const target=rows.filter(row=>Number(row.level)===Number(level)).sort(medalShareSort);
 if(!target.length)throw new Error(`Lv.${level} の譜面がありません。`);
 await preload(target);
 const width=900,pad=18,gap=7,{cols,rows:rowCount}=gridForCount(target.length),tileW=(width-pad*2-gap*(cols-1))/cols;
 const tileH=Math.max(54,Math.min(72,Math.round(tileW*.34)));
 const cleared=target.filter(row=>String(row.medal_code||"none").toLowerCase()!=="none").length,rate=target.length?Math.floor(cleared/target.length*10000)/100:0;
 const legendH=42,topH=84+legendH+14,height=topH+rowCount*(tileH+gap)+38;
 const[c,ctx]=canvas(width,height);
 header(ctx,`Lv.${level} メダル一覧`,`クリア率 ${rate.toFixed(2)}%`,username,width);
 await drawMedalLegend(ctx,target,pad,92,width-pad*2);
 let y=topH;
 for(let i=0;i<target.length;i++){
  const col=i%cols,row=Math.floor(i/cols);
  await drawLevelTile(ctx,target[i],pad+col*(tileW+gap),y+row*(tileH+gap),tileW,tileH);
 }
 footer(ctx,width,height);
 const blob=await blobFromCanvas(c);
 return shareBlob(blob,`popn_level${level}_${escFile(username)}.jpg`,`pop'n Score Manager Lv.${level} メダル一覧`);
}
