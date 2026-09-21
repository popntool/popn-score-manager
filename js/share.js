import{popClassSelection,songPopClass}from"./scores.js?v=3.2.3";
import{medalInfo}from"./ui.js?v=3.2.13";

const HASHTAG="#popn_score_manager",SHARE_TEXT=`${HASHTAG}\n`,BG="#fffaf0",PANEL="#fffdf6",INK="#142b67",MUTED="#69789d",LINE="#3153a0",ACCENT="#ffd851",PINK="#ff789a";
const TARGET_BYTES=1024*1024;

const FONT='system-ui,-apple-system,"Segoe UI","Noto Sans JP",sans-serif';
const imgCache=new Map();
const trimCache=new WeakMap();
const escFile=v=>String(v||"player").replace(/[\\/:*?"<>|\s]+/g,"_").slice(0,60)||"player";
const chartOrder={EX:0,HYPER:1,NORMAL:2,LIGHT:3};

function rounded(ctx,x,y,w,h,r=18,fill=PANEL,stroke=LINE,lw=3){ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fillStyle=fill;ctx.fill();if(stroke){ctx.lineWidth=lw;ctx.strokeStyle=stroke;ctx.stroke();}}
function text(ctx,value,x,y,size=28,weight=700,color=INK,align="left",baseline="middle"){ctx.font=`${weight} ${size}px ${FONT}`;ctx.fillStyle=color;ctx.textAlign=align;ctx.textBaseline=baseline;ctx.fillText(String(value??""),x,y);}
async function fetchBitmap(url){
 const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),6500);
 try{
  const response=await fetch(url,{mode:"cors",cache:"force-cache",signal:controller.signal});
  if(!response.ok)throw new Error(String(response.status));
  return await createImageBitmap(await response.blob());
 }finally{clearTimeout(timeout);}
}
async function loadImage(url){if(!url)return null;if(imgCache.has(url))return imgCache.get(url);const promise=(async()=>{try{return await fetchBitmap(url);}catch{try{const parsed=new URL(url,location.href);if(parsed.origin===location.origin)return null;return await fetchBitmap(`https://wsrv.nl/?url=${encodeURIComponent(parsed.href)}&output=png`);}catch{return null;}}})();imgCache.set(url,promise);return promise;}
function contain(ctx,img,x,y,w,h){if(!img)return false;const scale=Math.min(w/img.width,h/img.height),dw=img.width*scale,dh=img.height*scale;ctx.drawImage(img,x+(w-dw)/2,y+(h-dh)/2,dw,dh);return true;}
function trimBounds(img){
 if(!img)return null;if(trimCache.has(img))return trimCache.get(img);
 const c=document.createElement("canvas"),w=img.width,h=img.height;c.width=w;c.height=h;const cx=c.getContext("2d",{willReadFrequently:true});cx.drawImage(img,0,0);
 let minX=w,minY=h,maxX=-1,maxY=-1;try{const data=cx.getImageData(0,0,w,h).data;for(let y=0;y<h;y++)for(let x=0;x<w;x++)if(data[(y*w+x)*4+3]>12){if(x<minX)minX=x;if(x>maxX)maxX=x;if(y<minY)minY=y;if(y>maxY)maxY=y;}}catch{}
 const bounds=maxX>=minX&&maxY>=minY?{x:minX,y:minY,w:maxX-minX+1,h:maxY-minY+1}:{x:0,y:0,w,h};trimCache.set(img,bounds);return bounds;
}
function containTrimmed(ctx,img,x,y,w,h){if(!img)return false;const b=trimBounds(img),scale=Math.min(w/b.w,h/b.h),dw=b.w*scale,dh=b.h*scale;ctx.drawImage(img,b.x,b.y,b.w,b.h,x+(w-dw)/2,y+(h-dh)/2,dw,dh);return true;}
function containTrimmedSharp(ctx,img,x,y,w,h){if(!img)return false;ctx.save();ctx.imageSmoothingEnabled=false;const ok=containTrimmed(ctx,img,x,y,w,h);ctx.restore();return ok;}
function canonicalMedalCode(code){const normalized=String(code||"none").toLowerCase();for(const[key,codes]of MEDAL_GROUPS)if(codes.includes(normalized))return key;return normalized;}
function shareMedalUrl(code,score=0){if(Number(score)===100000)return "./assets/cool-perfect.png";const canonical=canonicalMedalCode(code);return medalInfo(canonical).url||medalInfo(code).url;}
function currentMedalCode(row){
 if(row.current_medal_code!=null)return row.current_medal_code;
 return {perfect:"perfect",full_combo:"fc_21_plus",clear:"clear_bad_21_plus",easy:"easy",long_off:"long_off",failed:Number(row.version_score)>0?"failed_0_11":"none"}[row.current_clear_status]||"none";
}
function effectiveMedal(row,useCurrent=false){const code=useCurrent?currentMedalCode(row):row.medal_code;const score=useCurrent?row.version_score:row.score;const info=Number(score)===100000?{label:"COOL PERFECT",url:"./assets/cool-perfect.png"}:medalInfo(canonicalMedalCode(code));return {...info,url:shareMedalUrl(code,score)};}
function medalFallback(ctx,label,x,y,size){ctx.save();ctx.translate(x+size/2,y+size/2);ctx.rotate(Math.PI/4);rounded(ctx,-size*.31,-size*.31,size*.62,size*.62,8,"#f5e8ad",LINE,3);ctx.restore();text(ctx,label==="－　未プレー"?"－":label.slice(0,2),x+size/2,y+size/2,15,900,INK,"center");}
async function drawMedal(ctx,row,x,y,size,useCurrent=false){const info=effectiveMedal(row,useCurrent),code=useCurrent?currentMedalCode(row):row.medal_code,score=useCurrent?row.version_score:row.score;if(String(code||"none").toLowerCase()==="none"&&Number(score)!==100000){text(ctx,"－",x+size/2,y+size/2,26,700,MUTED,"center");return;}const img=await loadImage(info.url);if(!containTrimmedSharp(ctx,img,x,y,size,size))medalFallback(ctx,info.label,x,y,size);}
function fitLine(ctx,value,x,y,maxWidth,maxSize=13,minSize=8,weight=800,color=INK){
 const raw=String(value||"").trim()||"NO IMAGE";let size=maxSize;ctx.textAlign="center";ctx.textBaseline="middle";
 while(size>minSize){ctx.font=`${weight} ${size}px ${FONT}`;if(ctx.measureText(raw).width<=maxWidth)break;size--;}
 let shown=raw;ctx.font=`${weight} ${size}px ${FONT}`;
 if(ctx.measureText(shown).width>maxWidth){while(shown.length>1&&ctx.measureText(`${shown}…`).width>maxWidth)shown=shown.slice(0,-1);shown+=shown===raw?"":"…";}
 ctx.fillStyle=color;ctx.fillText(shown,x,y);
}
async function drawBanner(ctx,row,x,y,w,h,stroke=true){rounded(ctx,x,y,w,h,5,"#f5f0df",null,0);const img=await loadImage(row.banner_url);if(!contain(ctx,img,x,y,w,h))fitLine(ctx,row.title,x+w/2,y+h/2,w-10,12,8,800,MUTED);if(stroke){ctx.lineWidth=1;ctx.strokeStyle=LINE;ctx.strokeRect(x,y,w,h);}}
function header(ctx,title,subtitle,username,width){
 ctx.fillStyle=ACCENT;ctx.fillRect(0,0,width,84);
 ctx.beginPath();ctx.arc(32,42,23,0,Math.PI*2);ctx.fillStyle=PINK;ctx.fill();ctx.lineWidth=4;ctx.strokeStyle=INK;ctx.stroke();
 text(ctx,"♪",32,42,29,900,"#fff","center");
 text(ctx,"pop'n Score Manager",62,33,22,900,INK);text(ctx,username||"PLAYER",62,59,14,700,MUTED);text(ctx,title,width-28,32,25,900,INK,"right");text(ctx,subtitle,width-28,59,14,700,MUTED,"right");
}
function footer(ctx,width,height){text(ctx,HASHTAG,width-36,height-25,16,800,MUTED,"right");}
async function preload(rows,extraUrls=[],useCurrent=false){const urls=new Set(["./assets/cool-perfect.png",...extraUrls]);for(const row of rows){if(row.banner_url)urls.add(row.banner_url);const m=effectiveMedal(row,useCurrent);if(m.url)urls.add(m.url);}const list=[...urls];let i=0;await Promise.all(Array.from({length:Math.min(12,list.length)},async()=>{while(i<list.length)await loadImage(list[i++]);}));}
function canvas(width,height){const c=document.createElement("canvas");c.width=width;c.height=height;const ctx=c.getContext("2d");ctx.fillStyle=BG;ctx.fillRect(0,0,width,height);return[c,ctx];}
async function blobFromCanvas(c,type="image/jpeg"){if(type==="image/png")return await new Promise((resolve,reject)=>c.toBlob(b=>b?resolve(b):reject(new Error("画像を作成できませんでした。")),"image/png"));let quality=.86,blob=null;for(let i=0;i<5;i++){blob=await new Promise((resolve,reject)=>c.toBlob(b=>b?resolve(b):reject(new Error("画像を作成できませんでした。")),"image/jpeg",quality));if(blob.size<=TARGET_BYTES||quality<=.58)break;quality-=.07;}return blob;}
async function shareBlob(blob,filename,title){const type=blob.type||(/\.png$/i.test(filename)?"image/png":"image/jpeg"),file=new File([blob],filename,{type}),data={files:[file],title,text:SHARE_TEXT};if(navigator.share&&(!navigator.canShare||navigator.canShare({files:[file]}))){try{await navigator.share(data);return"shared";}catch(error){if(error?.name==="AbortError")return"cancelled";}}const url=URL.createObjectURL(blob),a=document.createElement("a");a.href=url;a.download=filename;document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);return"downloaded";}

const CHART_STYLE={EX:["#ef426f","#fff"],HYPER:["#fff2a6","#7b6500"],NORMAL:["#bdf39a","#17652b"],LIGHT:["#c8e3ff","#24558d"]};
function chartLevelStack(ctx,chart,level,x,y,w,h){
 const[bg,fg]=CHART_STYLE[chart]||["#eef1f7",INK],chartH=Math.floor(h*.53),shortChart={LIGHT:"LT",NORMAL:"NM",HYPER:"HP",EX:"EX"}[chart]||String(chart||"").slice(0,2);rounded(ctx,x,y,w,chartH,4,bg,null,0);text(ctx,shortChart,x+w/2,y+chartH/2,10,900,fg,"center");text(ctx,String(level??"-"),x+w/2,y+chartH+Math.max(7,(h-chartH)/2),11,900,INK,"center");
}
function scoreTileLayout(row,x,y,w,h){
 const inner=3,cellGap=2,medalCellW=28,stackCellW=31,scoreCellW=44,psrCellW=42,bannerH=h-inner*2;
 const score=String(Number(row.version_score||0)),psr=songPopClass(row).toFixed(2);
 const fixedW=medalCellW+stackCellW+scoreCellW+psrCellW+cellGap*4;
 const bannerW=Math.max(96,Math.floor(w-inner*2-fixedW));
 const banner={x:x+inner,y:y+inner,w:bannerW,h:bannerH};
 const medal={x:banner.x+banner.w+cellGap,y:y+inner,w:medalCellW,h:bannerH};
 const stack={x:medal.x+medal.w+cellGap,y:y+inner,w:stackCellW,h:bannerH};
 const scoreCell={x:stack.x+stack.w+cellGap,y:y+inner,w:scoreCellW,h:bannerH};
 const psrCell={x:scoreCell.x+scoreCell.w+cellGap,y:y+inner,w:psrCellW,h:bannerH};
 return{banner,medal,stack,scoreCell,psrCell,score,psr};
}
function drawMetricColumn(ctx,label,value,cell){
 text(ctx,label,cell.x+cell.w/2,cell.y+Math.round(cell.h*.30),8.2,800,MUTED,"center");
 text(ctx,value,cell.x+cell.w/2,cell.y+Math.round(cell.h*.72),9.5,900,INK,"center");
}
async function drawScoreTile(ctx,row,x,y,w,h){
 rounded(ctx,x,y,w,h,7,PANEL,LINE,2);
 const cell=scoreTileLayout(row,x,y,w,h);
 await drawBanner(ctx,row,cell.banner.x,cell.banner.y,cell.banner.w,cell.banner.h,false);
 const medalSize=Math.min(24,cell.medal.h);
 await drawMedal(ctx,row,cell.medal.x+(cell.medal.w-medalSize)/2,cell.medal.y+(cell.medal.h-medalSize)/2,medalSize,true);
 chartLevelStack(ctx,row.chart,row.level,cell.stack.x,cell.stack.y,cell.stack.w,cell.stack.h);
 drawMetricColumn(ctx,"スコア",cell.score,cell.scoreCell);
 drawMetricColumn(ctx,"PSR",cell.psr,cell.psrCell);
}
function columnHeader(ctx,label,count,x,y,w){text(ctx,label,x,y+13,16,900,INK);text(ctx,`${count}曲`,x+w,y+13,11,800,MUTED,"right");ctx.fillStyle=LINE;ctx.fillRect(x,y+26,w,2);}
export async function sharePopClassImage(rows,username,officialPopnClass=null){
 const{current,other,total}=popClassSelection(rows),all=[...current,...other];if(!all.length)throw new Error("PSR対象曲がありません。");
 await preload(all,[],true);
 const width=900,pad=15,gapX=7,gapY=5,cols=3,rowsPerCol=20,tileW=(width-pad*2-gapX*(cols-1))/cols,tileH=45,gridY=123;
 const height=gridY+rowsPerCol*(tileH+gapY)+29;
 const[c,ctx]=canvas(width,height),hasOfficial=officialPopnClass!==null&&officialPopnClass!==""&&Number.isFinite(Number(officialPopnClass)),official=hasOfficial?Number(officialPopnClass):null;header(ctx,"Popn Score Rating 対象曲一覧",`${hasOfficial?`ポップンクラス ${official.toFixed(2)}　`:""}PSR ${total.toFixed(2)}`,username,width);
 columnHeader(ctx,"今作 TOP 20",current.length,pad,87,tileW);
 columnHeader(ctx,"その他 TOP 40",other.length,pad+tileW+gapX,87,tileW*2+gapX);
 const columns=[current,other.slice(0,20),other.slice(20,40)];
 for(let col=0;col<cols;col++)for(let row=0;row<columns[col].length;row++)await drawScoreTile(ctx,columns[col][row],pad+col*(tileW+gapX),gridY+row*(tileH+gapY),tileW,tileH);
 footer(ctx,width,height);return shareBlob(await blobFromCanvas(c),`popn_psr_${escFile(username)}.jpg`,"pop'n Score Manager Popn Score Rating 対象曲一覧");
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
  else{const img=await loadImage(item.url);if(img)containTrimmedSharp(ctx,img,center-16,y+5,32,32);}
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
 const registered=target.filter(row=>!noPlay(row)),code=row=>String(row.medal_code||"none").toLowerCase(),failed=row=>/^(h|i|j|l|m|n)$/.test(code(row))||code(row).startsWith("failed_"),cleared=registered.filter(row=>code(row)!=="none"&&code(row)!=="easy"&&code(row)!=="k"&&code(row)!=="long_off"&&!failed(row)).length,rate=registered.length?Math.floor(cleared/registered.length*10000)/100:0;
 const summaryY=91,summaryH=64,gridY=163,height=gridY+rowCount*(tileH+gap)+31;
 const[c,ctx]=canvas(width,height);header(ctx,`Lv.${level} メダル一覧`,`クリア率 ${rate.toFixed(2)}%`,username,width);await drawMedalSummary(ctx,target,pad,summaryY,width-pad*2,summaryH);
 for(let i=0;i<target.length;i++){const col=i%cols,row=Math.floor(i/cols);await drawLevelTile(ctx,target[i],pad+col*(tileW+gap),gridY+row*(tileH+gap),tileW,tileH);}
 footer(ctx,width,height);return shareBlob(await blobFromCanvas(c),`popn_level${level}_${escFile(username)}.jpg`,`pop'n Score Manager Lv.${level} メダル一覧`);
}


function distributionItems(rowsByLevel,levels){
 const itemDefs=[
  {type:"cool",key:"cool",url:"./assets/cool-perfect.png",label:"COOL PERFECT",countFor:(rows,code)=>rows.filter(row=>Number(row.score)===100000).length},
  ...MEDAL_GROUPS.filter(([key])=>key!=="none").map(([key,codes])=>{const info=medalInfo(key);return{type:"image",key,url:info.url,label:info.label,countFor:(rows,code)=>rows.filter(row=>codes.includes(code(row))&&(key!=="perfect"||Number(row.score)!==100000)).length};}),
  {type:"dash",key:"dash",label:"－",countFor:(rows,code)=>rows.filter(row=>!noPlay(row)&&code(row)==="none").length},
  {type:"no-play",key:"no_play",label:"NO PLAY",countFor:rows=>rows.filter(noPlay).length}
 ];
 return itemDefs.map(item=>({...item,counts:levels.map(level=>item.countFor(rowsByLevel.get(level)||[],row=>String(row.medal_code||"none").toLowerCase()))}));
}
async function drawDistributionIcon(ctx,item,x,y,w,h){
 if(item.type==="dash"){text(ctx,"－",x+w/2,y+h/2,18,800,MUTED,"center");return;}
 if(item.type==="no-play"){text(ctx,"NO",x+w/2,y+h/2-7,8,800,MUTED,"center");text(ctx,"PLAY",x+w/2,y+h/2+6,8,800,MUTED,"center");return;}
 const img=await loadImage(item.url);if(img){containTrimmedSharp(ctx,img,x+2,y+2,w-4,h-4);return;}
 medalFallback(ctx,item.label,x+(w-30)/2,y+(h-30)/2,30);
}
export async function shareMedalDistributionImage(rows,startLevel,endLevel,username){
 let start=Number(startLevel),end=Number(endLevel);if(!Number.isFinite(start)||!Number.isFinite(end))throw new Error("開始レベルと終了レベルを選択してください。");if(start>end)[start,end]=[end,start];
 const levels=[];for(let level=end;level>=start;level--)levels.push(level);
 const target=rows.filter(row=>Number(row.level)>=start&&Number(row.level)<=end);
 if(!target.length)throw new Error(`Lv.${start}〜${end} の譜面がありません。`);
 const rowsByLevel=new Map(levels.map(level=>[level,target.filter(row=>Number(row.level)===level)]));
 const items=distributionItems(rowsByLevel,levels),legendUrls=[...new Set(items.filter(item=>item.url).map(item=>item.url))];
 const missing=await Promise.all(legendUrls.map(async url=>({url,image:await loadImage(url)})));
 if(missing.some(item=>!item.image))throw new Error("公式メダル画像を読み込めませんでした。通信環境を確認して再度お試しください。");
 const pad=18,leftW=64,colW=52,rowH=40,headerH=56,tableW=leftW+items.length*colW,width=Math.max(940,pad*2+tableW),tableX=Math.round((width-tableW)/2),tableY=96,height=tableY+headerH+levels.length*rowH+34;
 const[c,ctx]=canvas(width,height);header(ctx,`Lv.${start}〜${end} 歴代メダル分布`,`対象 ${target.length.toLocaleString("ja-JP")}譜面`,username,width);
 rounded(ctx,tableX,tableY,tableW,headerH+levels.length*rowH,10,PANEL,LINE,2);
 ctx.strokeStyle="#e6dfc7";ctx.lineWidth=1;
 for(let i=0;i<=items.length;i++){const x=tableX+leftW+i*colW;ctx.beginPath();ctx.moveTo(x,tableY);ctx.lineTo(x,tableY+headerH+levels.length*rowH);ctx.stroke();}
 ctx.beginPath();ctx.moveTo(tableX+leftW,tableY);ctx.lineTo(tableX+leftW,tableY+headerH+levels.length*rowH);ctx.stroke();
 ctx.beginPath();ctx.moveTo(tableX,tableY+headerH);ctx.lineTo(tableX+tableW,tableY+headerH);ctx.stroke();
 for(let i=1;i<levels.length;i++){const y=tableY+headerH+i*rowH;ctx.beginPath();ctx.moveTo(tableX,y);ctx.lineTo(tableX+tableW,y);ctx.stroke();}
  for(let cIndex=0;cIndex<items.length;cIndex++)await drawDistributionIcon(ctx,items[cIndex],tableX+leftW+cIndex*colW+8,tableY+8,colW-16,headerH-16);
 for(let r=0;r<levels.length;r++){
   const level=levels[r],rowY=tableY+headerH+r*rowH; text(ctx,`Lv.${level}`,tableX+leftW/2,rowY+rowH/2,13,900,INK,"center");
   items.forEach((item,cIndex)=>{const count=item.counts[r],color=count===0?MUTED:INK;text(ctx,count.toLocaleString("ja-JP"),tableX+leftW+cIndex*colW+colW/2,rowY+rowH/2,12,800,color,"center");});
 }
 footer(ctx,width,height);return shareBlob(await blobFromCanvas(c,"image/png"),`popn_medal_distribution_lv${start}-${end}_${escFile(username)}.png`,`pop'n Score Manager Lv.${start}〜${end} 歴代メダル分布`);
}
