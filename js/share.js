import{popClassSelection,songPopClass}from"./scores.js?v=3.0.40";
import{medalInfo}from"./ui.js?v=3.0.37";

const HASHTAG="#popn_score_manager",SHARE_TEXT=`${HASHTAG}\n`,BG="#fffaf0",PANEL="#fffdf6",INK="#142b67",MUTED="#69789d",LINE="#3153a0",ACCENT="#ffd851",BLUE="#68bdf0";
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
function cover(ctx,img,x,y,w,h){if(!img)return false;const scale=Math.max(w/img.width,h/img.height),sw=w/scale,sh=h/scale,sx=(img.width-sw)/2,sy=(img.height-sh)/2;ctx.drawImage(img,sx,sy,sw,sh,x,y,w,h);return true;}
function contain(ctx,img,x,y,w,h){if(!img)return false;const scale=Math.min(w/img.width,h/img.height),dw=img.width*scale,dh=img.height*scale;ctx.drawImage(img,x+(w-dw)/2,y+(h-dh)/2,dw,dh);return true;}
function effectiveMedal(row){return Number(row.score)===100000?{label:"COOL PERFECT",url:"./assets/cool-perfect.png"}:medalInfo(row.medal_code);}
function medalFallback(ctx,label,x,y,size){ctx.save();ctx.translate(x+size/2,y+size/2);ctx.rotate(Math.PI/4);rounded(ctx,-size*.31,-size*.31,size*.62,size*.62,8,"#f5e8ad",LINE,3);ctx.restore();text(ctx,label==="－　未プレー"?"－":label.slice(0,2),x+size/2,y+size/2,15,900,INK,"center");}
async function drawMedal(ctx,row,x,y,size){const info=effectiveMedal(row);if(String(row.medal_code||"none").toLowerCase()==="none"&&Number(row.score)!==100000){text(ctx,"－",x+size/2,y+size/2,26,700,MUTED,"center");return;}const img=await loadImage(info.url);if(!contain(ctx,img,x,y,size,size))medalFallback(ctx,info.label,x,y,size);}
async function drawBanner(ctx,row,x,y,w,h){rounded(ctx,x,y,w,h,8,"#f5f0df",null,0);const img=await loadImage(row.banner_url);if(!cover(ctx,img,x,y,w,h)){text(ctx,"NO IMAGE",x+w/2,y+h/2,18,800,MUTED,"center");}ctx.lineWidth=1;ctx.strokeStyle=LINE;ctx.strokeRect(x,y,w,h);}
function header(ctx,title,subtitle,username,width){ctx.fillStyle=ACCENT;ctx.fillRect(0,0,width,112);text(ctx,"♪",44,56,42,900,"#fff","center");ctx.beginPath();ctx.arc(44,56,31,0,Math.PI*2);ctx.lineWidth=4;ctx.strokeStyle=INK;ctx.stroke();text(ctx,"pop'n Score Manager",90,44,30,900,INK);text(ctx,username||"PLAYER",90,78,19,700,MUTED);text(ctx,title,width-42,43,34,900,INK,"right");text(ctx,subtitle,width-42,78,19,700,MUTED,"right");}
function footer(ctx,width,height){text(ctx,HASHTAG,width-36,height-30,18,800,MUTED,"right");}
async function preload(rows){const urls=new Set(["./assets/cool-perfect.png"]);for(const row of rows){if(row.banner_url)urls.add(row.banner_url);const m=effectiveMedal(row);if(m.url)urls.add(m.url);}const list=[...urls];let i=0;await Promise.all(Array.from({length:Math.min(8,list.length)},async()=>{while(i<list.length){const url=list[i++];await loadImage(url);}}));}
function canvas(width,height){const c=document.createElement("canvas");c.width=width;c.height=height;const ctx=c.getContext("2d");ctx.fillStyle=BG;ctx.fillRect(0,0,width,height);return[c,ctx];}
async function blobFromCanvas(c){return await new Promise((resolve,reject)=>c.toBlob(blob=>blob?resolve(blob):reject(new Error("画像を作成できませんでした。")),"image/png"));}
async function shareBlob(blob,filename,title){const file=new File([blob],filename,{type:"image/png"}),data={files:[file],title,text:SHARE_TEXT};if(navigator.share&&(!navigator.canShare||navigator.canShare({files:[file]}))){try{await navigator.share(data);return"shared";}catch(error){if(error?.name==="AbortError")return"cancelled";}}
const url=URL.createObjectURL(blob),a=document.createElement("a");a.href=url;a.download=filename;document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);return"downloaded";}

async function drawScoreTile(ctx,row,x,y,w,h){
 rounded(ctx,x,y,w,h,14,PANEL,LINE,2);
 await drawBanner(ctx,row,x+10,y+10,154,54);
 await drawMedal(ctx,row,x+174,y+10,50);
 const contentX=x+236,metricW=126,titleW=Math.max(80,w-(contentX-x)-metricW-14);
 text(ctx,ellipsize(ctx,row.title,titleW,19,900),contentX,y+28,19,900,INK);
 text(ctx,`${row.chart}  Lv.${row.level}`,contentX,y+61,16,800,MUTED);
 text(ctx,`今作 ${Number(row.version_score||0).toLocaleString("ja-JP")}`,x+w-14,y+27,15,800,INK,"right");
 text(ctx,`ポックラ ${songPopClass(row).toFixed(2)}`,x+w-14,y+61,15,900,INK,"right");
}
function sectionTitle(ctx,label,count,x,y,w){text(ctx,label,x,y+24,28,900,INK);text(ctx,`${count}曲`,x+w,y+24,18,800,MUTED,"right");ctx.fillStyle=LINE;ctx.fillRect(x,y+47,w,3);}
export async function sharePopClassImage(rows,username){const {current,other,total}=popClassSelection(rows),all=[...current,...other];if(!all.length)throw new Error("ポックラ対象曲がありません。");await preload(all);const width=1200,pad=34,gap=14,tileW=(width-pad*2-gap)/2,tileH=88;const curRows=Math.ceil(current.length/2),otherRows=Math.ceil(other.length/2),height=112+74+curRows*(tileH+gap)+72+otherRows*(tileH+gap)+64;const[c,ctx]=canvas(width,height);header(ctx,"ポックラ対象一覧",`TOTAL ${total.toFixed(2)}`,username,width);let y=132;sectionTitle(ctx,"今作 TOP 20",current.length,pad,y,width-pad*2);y+=64;for(let i=0;i<current.length;i++){const col=i%2,row=Math.floor(i/2);await drawScoreTile(ctx,current[i],pad+col*(tileW+gap),y+row*(tileH+gap),tileW,tileH);}y+=curRows*(tileH+gap)+8;sectionTitle(ctx,"その他 TOP 40",other.length,pad,y,width-pad*2);y+=64;for(let i=0;i<other.length;i++){const col=i%2,row=Math.floor(i/2);await drawScoreTile(ctx,other[i],pad+col*(tileW+gap),y+row*(tileH+gap),tileW,tileH);}footer(ctx,width,height);const blob=await blobFromCanvas(c);return shareBlob(blob,`popn_popclass_${escFile(username)}.png`,"pop'n Score Manager ポックラ対象一覧");}

async function drawLevelTile(ctx,row,x,y,w,h){
 rounded(ctx,x,y,w,h,12,PANEL,LINE,2);
 await drawBanner(ctx,row,x+8,y+8,w-16,58);
 await drawMedal(ctx,row,x+10,y+76,48);
 const info=effectiveMedal(row),unplayed=String(row.medal_code||"none").toLowerCase()==="none"&&Number(row.score)!==100000,label=unplayed?"未プレー":info.label;
 text(ctx,ellipsize(ctx,row.title,w-86,19,900),x+70,y+91,19,900,INK);
 text(ctx,`${row.chart}  Lv.${row.level}`,x+70,y+119,15,800,MUTED);
 text(ctx,label,x+w-12,y+119,13,800,MUTED,"right");
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
export async function shareLevelMedalImage(rows,level,username){const target=rows.filter(row=>Number(row.level)===Number(level)).sort(medalShareSort);if(!target.length)throw new Error(`Lv.${level} の譜面がありません。`);await preload(target);const width=1200,pad=30,gap=12,cols=3,tileW=(width-pad*2-gap*(cols-1))/cols,tileH=140,rowCount=Math.ceil(target.length/cols),height=112+68+rowCount*(tileH+gap)+58;const[c,ctx]=canvas(width,height);const cleared=target.filter(row=>String(row.medal_code||"none").toLowerCase()!=="none").length;header(ctx,`Lv.${level} メダル一覧`,`${cleared}/${target.length} 譜面`,username,width);let y=140;text(ctx,"バナー・クリアメダル一覧",pad,y+18,25,900,INK);y+=56;for(let i=0;i<target.length;i++){const col=i%cols,row=Math.floor(i/cols);await drawLevelTile(ctx,target[i],pad+col*(tileW+gap),y+row*(tileH+gap),tileW,tileH);}footer(ctx,width,height);const blob=await blobFromCanvas(c);return shareBlob(blob,`popn_level${level}_${escFile(username)}.png`,`pop'n Score Manager Lv.${level} メダル一覧`);}
