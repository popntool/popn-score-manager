import{popClassSelection,songPopClass}from"./scores.js?v=3.0.55";
import{medalInfo}from"./ui.js?v=3.0.37";

const HASHTAG="#popn_score_manager",SHARE_TEXT=`${HASHTAG}\n`,BG="#fffaf0",PANEL="#fffdf6",INK="#142b67",MUTED="#69789d",LINE="#3153a0",ACCENT="#ffd851",PINK="#ff789a";
const TARGET_BYTES=1024*1024;
const FONT='system-ui,-apple-system,"Segoe UI","Noto Sans JP",sans-serif';
const imgCache=new Map();
const trimCache=new WeakMap();
const escFile=v=>String(v||"player").replace(/[\\/:*?"<>|\s]+/g,"_").slice(0,60)||"player";
const chartOrder={EX:0,HYPER:1,NORMAL:2,LIGHT:3};

function rounded(ctx,x,y,w,h,r=18,fill=PANEL,stroke=LINE,lw=3){ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fillStyle=fill;ctx.fill();if(stroke){ctx.lineWidth=lw;ctx.strokeStyle=stroke;ctx.stroke();}}
function text(ctx,value,x,y,size=28,weight=700,color=INK,align="left",baseline="middle"){ctx.font=`${weight} ${size}px ${FONT}`;ctx.fillStyle=color;ctx.textAlign=align;ctx.textBaseline=baseline;ctx.fillText(String(value??""),x,y);}
async function fetchBitmap(url){const response=await fetch(url,{mode:"cors",cache:"force-cache"});if(!response.ok)throw new Error(String(response.status));return createImageBitmap(await response.blob());}
async function loadImage(url){if(!url)return null;if(imgCache.has(url))return imgCache.get(url);const promise=(async()=>{try{return await fetchBitmap(url);}catch{try{const parsed=new URL(url,location.href);if(parsed.origin===location.origin)return null;return await fetchBitmap(`https://wsrv.nl/?url=${encodeURIComponent(parsed.href)}&output=png`);}catch{return null;}}})();imgCache.set(url,promise);return promise;}
function contain(ctx,img,x,y,w,h){if(!img)return false;const scale=Math.min(w/img.width,h/img.height),dw=img.width*scale,dh=img.height*scale;ctx.drawImage(img,x+(w-dw)/2,y+(h-dh)/2,dw,dh);return true;}
function trimBounds(img){
 if(!img)return null;if(trimCache.has(img))return trimCache.get(img);
 const c=document.createElement("canvas"),w=img.width,h=img.height;c.width=w;c.height=h;const cx=c.getContext("2d",{willReadFrequently:true});cx.drawImage(img,0,0);
 let minX=w,minY=h,maxX=-1,maxY=-1;try{const data=cx.getImageData(0,0,w,h).data;for(let y=0;y<h;y++)for(let x=0;x<w;x++)if(data[(y*w+x)*4+3]>12){if(x<minX)minX=x;if(x>maxX)maxX=x;if(y<minY)minY=y;if(y>maxY)maxY=y;}}catch{}
 const bounds=maxX>=minX&&maxY>=minY?{x:minX,y:minY,w:maxX-minX+1,h:maxY-minY+1}:{x:0,y:0,w,h};trimCache.set(img,bounds);return bounds;
}
function containTrimmed(ctx,img,x,y,w,h){if(!img)return false;const b=trimBounds(img),scale=Math.min(w/b.w,h/b.h),dw=b.w*scale,dh=b.h*scale;ctx.drawImage(img,b.x,b.y,b.w,b.h,x+(w-dw)/2,y+(h-dh)/2,dw,dh);return true;}
function effectiveMedal(row){return Number(row.score)===100000?{label:"COOL PERFECT",url:"./assets/cool-perfect.png"}:medalInfo(row.medal_code);}
function medalFallback(ctx,label,x,y,size){ctx.save();ctx.translate(x+size/2,y+size/2);ctx.rotate(Math.PI/4);rounded(ctx,-size*.31,-size*.31,size*.62,size*.62,8,"#f5e8ad",LINE,3);ctx.restore();text(ctx,label==="－　未プレー"?"－":label.slice(0,2),x+size/2,y+size/2,15,900,INK,"center");}
async function drawMedal(ctx,row,x,y,size){const info=effectiveMedal(row);if(String(row.medal_code||"none").toLowerCase()==="none"&&Number(row.score)!==100000){text(ctx,"－",x+size/2,y+size/2,26,700,MUTED,"center");return;}const img=await loadImage(info.url);if(!containTrimmed(ctx,img,x,y,size,size))medalFallback(ctx,info.label,x,y,size);}
function fitLine(ctx,value,x,y,maxWidth,maxSize=13,minSize=8,weight=800,color=INK){
 const raw=String(value||"").trim()||"NO IMAGE";let size=maxSize;ctx.textAlign="center";ctx.textBaseline="middle";
 while(size>minSize){ctx.font=`${weight} ${size}px ${FONT}`;if(ctx.measureText(raw).width<=maxWidth)break;size--;}
 let shown=raw;ctx.font=`${weight} ${size}px ${FONT}`;
 if(ctx.measureText(shown).width>maxWidth){while(shown.length>1&&ctx.measureText(`${shown}…`).width>maxWidth)shown=shown.slice(0,-1);shown+=shown===raw?"":"…";}
 ctx.fillStyle=color;ctx.fillText(shown,x,y);
}
async function drawBanner(ctx,row,x,y,w,h){rounded(ctx,x,y,w,h,5,"#f5f0df",null,0);const img=await loadImage(row.banner_url);if(!contain(ctx,img,x,y,w,h))fitLine(ctx,row.title,x+w/2,y+h/2,w-10,12,8,800,MUTED);ctx.lineWidth=1;ctx.strokeStyle=LINE;ctx.strokeRect(x,y,w,h);}
function header(ctx,title,subtitle,username,width){
 ctx.fillStyle=ACCENT;ctx.fillRect(0,0,width,84);
 ctx.beginPath();ctx.arc(32,42,23,0,Math.PI*2);ctx.fillStyle=PINK;ctx.fill();ctx.lineWidth=4;ctx.strokeStyle=INK;ctx.stroke();
 text(ctx,"♪",32,42,29,900,"#fff","center");
 text(ctx,"pop'n Score Manager",62,33,22,900,INK);text(ctx,username||"PLAYER",62,59,14,700,MUTED);text(ctx,title,width-28,32,25,900,INK,"right");text(ctx,subtitle,width-28,59,14,700,MUTED,"right");
}
function footer(ctx,width,height){text(ctx,HASHTAG,width-36,height-25,16,800,MUTED,"right");}
async function preload(rows,extraUrls=[]){const urls=new Set(["./assets/cool-perfect.png",...extraUrls]);for(const row of rows){if(row.banner_url)urls.add(row.banner_url);const m=effectiveMedal(row);if(m.url)urls.add(m.url);}const list=[...urls];let i=0;await Promise.all(Array.from({length:Math.min(12,list.length)},async()=>{while(i<list.length)await loadImage(list[i++]);}));}
function canvas(width,height){const c=document.createElement("canvas");c.width=width;c.height=height;const ctx=c.getContext("2d");ctx.fillStyle=BG;ctx.fillRect(0,0,width,height);return[c,ctx];}
async function blobFromCanvas(c){let quality=.86,blob=null;for(let i=0;i<5;i++){blob=await new Promise((resolve,reject)=>c.toBlob(b=>b?resolve(b):reject(new Error("画像を作成できませんでした。")),"image/jpeg",quality));if(blob.size<=TARGET_BYTES||quality<=.58)break;quality-=.07;}return blob;}
async function shareBlob(blob,filename,title){const file=new File([blob],filename,{type:"image/jpeg"}),data={files:[file],title,text:SHARE_TEXT};if(navigator.share&&(!navigator.canShare||navigator.canShare({files:[file]}))){try{await navigator.share(data);return"shared";}catch(error){if(error?.name==="AbortError")return"cancelled";}}const url=URL.createObjectURL(blob),a=document.createElement("a");a.href=url;a.download=filename;document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);return"downloaded";}

const CHART_STYLE={EX:["#ef426f","#fff"],HYPER:["#fff2a6","#7b6500"],NORMAL:["#bdf39a","#17652b"],LIGHT:["#c8e3ff","#24558d"]};
function chartLevelStack(ctx,chart,level,x,y,w,h){
 const[bg,fg]=CHART_STYLE[chart]||["#eef1f7",INK],chartH=Math.floor(h*.53),shortChart={LIGHT:"LT",NORMAL:"NM",HYPER:"HP",EX:"EX"}[chart]||String(chart||"").slice(0,2);rounded(ctx,x,y,w,chartH,4,bg,null,0);text(ctx,shortChart,x+w/2,y+chartH/2,10,900,fg,"center");text(ctx,String(level??"-"),x+w/2,y+chartH+Math.max(7,(h-chartH)/2),11,900,INK,"center");
}
async function drawScoreTile(ctx,row,x,y,w,h){
 rounded(ctx,x,y,w,h,7,PANEL,LINE,2);
 const bannerW=122,bannerH=h-8,medalSize=Math.min(25,h-14),stackW=30;
 await drawBanner(ctx,row,x+4,y+4,bannerW,bannerH);
 await drawMedal(ctx,row,x+129,y+(h-medalSize)/2,medalSize);
 chartLevelStack(ctx,row.chart,row.level,x+158,y+4,stackW,h-8);
 const valueX=x+193;
 text(ctx,`スコア ${String(Number(row.version_score||0)).padStart(5,"0")}`,valueX,y+16,10,800,INK,"left");
 text(ctx,`ポックラ ${songPopClass(row).toFixed(2)}`,valueX,y+31,10,900,INK,"left");
}
function columnHeader(ctx,label,count,x,y,w){text(ctx,label,x,y+13,16,900,INK);text(ctx,`${count}曲`,x+w,y+13,11,800,MUTED,"right");ctx.fillStyle=LINE;ctx.fillRect(x,y+26,w,2);}
export async function sharePopClassImage(rows,username){
 const{current,other,total}=popClassSelection(rows),all=[...current,...other];if(!all.length)throw new Error("ポックラ対象曲がありません。");
 await preload(all);
 const width=900,pad=15,gapX=7,gapY=5,cols=3,rowsPerCol=20,tileW=(width-pad*2-gapX*(cols-1))/cols,tileH=45,gridY=116;
 const height=gridY+rowsPerCol*(tileH+gapY)+29;
 const[c,ctx]=canvas(width,height);header(ctx,"ポックラ対象一覧",`TOTAL ${total.toFixed(2)}`,username,width);
 columnHeader(ctx,"今作 TOP 20",current.length,pad,87,tileW);
 columnHeader(ctx,"その他 TOP 40",other.length,pad+tileW+gapX,87,tileW*2+gapX);
 const columns=[current,other.slice(0,20),other.slice(20,40)];
 for(let col=0;col<cols;col++)for(let row=0;row<columns[col].length;row++)await drawScoreTile(ctx,columns[col][row],pad+col*(tileW+gapX),gridY+row*(tileH+gapY),tileW,tileH);
 footer(ctx,width,height);return shareBlob(await blobFromCanvas(c),`popn_popclass_${escFile(username)}.jpg`,"pop'n Score Manager ポックラ対象一覧");
}

const MEDAL_GROUPS=[
 ["perfect",["perfect","a"]],["fc_1_5",["fc_1_5","b"]],["fc_6_20",["fc_6_20","c"]],["fc_21_plus",["fc_21_plus","d"]],
 ["clear_bad_1_5",["clear_bad_1_5","e"]],["clear_bad_6_20",["clear_bad_6_20","f"]],["clear_bad_21_plus",["clear_bad_21_plus","g"]],
 ["long_off",["long_off"]],["easy",["easy","k"]],["failed_15_16",["failed_15_16","h","l"]],["failed_12_14",["failed_12_14","i","m"]],["failed_0_11",["failed_0_11","j","n"]],["none",["none"]]
];
function medalOrder(code){const normalized=String(code||"none").toLowerCase(),index=MEDAL_GROUPS.findIndex(([,codes])=>codes.includes(normalized));return index<0?MEDAL_GROUPS.length:index;}
function medalShareSort(a,b){const value=row=>Number(row.score)===100000?-1:medalOrder(row.medal_code);return value(a)-value(b)||Number(b.level||0)-Number(a.level||0)||Number(b.version_score||0)-Number(a.version_score||0)||Number(b.score||0)-Number(a.score||0)||songPopClass(b)-songPopClass(a)||String(a.title||"").localeCompare(String(b.title||""),"ja")||(chartOrder[a.chart]??9)-(chartOrder[b.chart]??9);}
function noPlay(row){return Number(row.score)<=0&&Number(row.version_score)<=0&&String(row.medal_code||"none").toLowerCase()==="none";}
function levelMedalStats(rows){
 const code=row=>String(row.medal_code||"none").toLowerCase(),registered=rows.filter(row=>!noPlay(row)),unplayed=registered.filter(row=>code(row)==="none");
 const items=[{type:"cool",count:registered.filter(row=>Number(row.score)===100000).length,url:"./assets/cool-perfect.png"}];
 for(const[key,codes]of MEDAL_GROUPS.filter(([key])=>key!=="none")){const info=medalInfo(key);items.push({type:"image",count:registered.filter(row=>codes.includes(code(row))&&(key!=="perfect"||Number(row.score)!==100000)).length,url:info.url,label:info.label});}
 items.push({type:"dash",count:unplayed.length},{type:"no-play",count:rows.filter(noPlay).length});
 return items;
}
async function drawMedalSummary(ctx,rows,x,y,w,h){
 const items=levelMedalStats(rows),cellW=w/items.length;
 rounded(ctx,x,y,w,h,8,PANEL,LINE,2);
 for(let i=1;i<items.length;i++){ctx.strokeStyle="#e6dfc7";ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(x+i*cellW,y);ctx.lineTo(x+i*cellW,y+h);ctx.stroke();}
 for(let i=0;i<items.length;i++){
  const item=items[i],center=x+i*cellW+cellW/2;
  if(item.type==="dash")text(ctx,"－",center,y+19,18,800,MUTED,"center");
  else if(item.type==="no-play"){text(ctx,"NO",center,y+14,8,800,MUTED,"center");text(ctx,"PLAY",center,y+24,8,800,MUTED,"center");}
  else{const img=await loadImage(item.url);if(img)containTrimmed(ctx,img,center-16,y+5,32,32);}
  text(ctx,item.count.toLocaleString("ja-JP"),center,y+h-12,12,900,INK,"center");
 }
}
async function drawLevelTile(ctx,row,x,y,w,h){
 rounded(ctx,x,y,w,h,7,PANEL,LINE,2);
 const medalSize=Math.min(34,h-10),medalArea=52;
 await drawBanner(ctx,row,x+5,y+5,w-medalArea-10,h-10);
 await drawMedal(ctx,row,x+w-medalArea+(medalArea-medalSize)/2-2,y+(h-medalSize)/2,medalSize);
}
export async function shareLevelMedalImage(rows,level,username){
 const target=rows.filter(row=>Number(row.level)===Number(level)).sort(medalShareSort);if(!target.length)throw new Error(`Lv.${level} の譜面がありません。`);
 const stats=levelMedalStats(target),legendUrls=stats.filter(item=>item.url).map(item=>item.url);await preload(target,legendUrls);
 const width=900,pad=18,gap=6,cols=4,rowCount=Math.ceil(target.length/cols),tileW=(width-pad*2-gap*(cols-1))/cols,tileH=50;
 const registered=target.filter(row=>!noPlay(row)),failed=row=>/^(h|i|j|l|m|n)$/.test(String(row.medal_code||"none").toLowerCase())||String(row.medal_code||"").toLowerCase().startsWith("failed_"),cleared=registered.filter(row=>String(row.medal_code||"none").toLowerCase()!=="none"&&!failed(row)).length,rate=registered.length?Math.floor(cleared/registered.length*10000)/100:0;
 const summaryY=91,summaryH=64,gridY=163,height=gridY+rowCount*(tileH+gap)+31;
 const[c,ctx]=canvas(width,height);header(ctx,`Lv.${level} メダル一覧`,`クリア率 ${rate.toFixed(2)}%`,username,width);await drawMedalSummary(ctx,target,pad,summaryY,width-pad*2,summaryH);
 for(let i=0;i<target.length;i++){const col=i%cols,row=Math.floor(i/cols);await drawLevelTile(ctx,target[i],pad+col*(tileW+gap),gridY+row*(tileH+gap),tileW,tileH);}
 footer(ctx,width,height);return shareBlob(await blobFromCanvas(c),`popn_level${level}_${escFile(username)}.jpg`,`pop'n Score Manager Lv.${level} メダル一覧`);
}
