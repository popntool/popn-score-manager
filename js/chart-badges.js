// Shared badge geometry and palette for DOM SVG and Canvas image sharing.
// This draws a visual approximation of the supplied game screenshots without
// embedding image assets or changing any chart identifiers.
export const BADGE_PALETTE=Object.freeze({
 LIGHT:Object.freeze({edge:'#86cfff',outer:'#58aeee',face:'#1689d3',top:'#269fe1',bottom:'#0870bb',glow:'#b4e7ff'}),
 NORMAL:Object.freeze({edge:'#92e89a',outer:'#5cc973',face:'#0eab38',top:'#36c65b',bottom:'#07852b',glow:'#c6f8bd'}),
 HYPER:Object.freeze({edge:'#ffe37a',outer:'#f4c548',face:'#f1b70c',top:'#ffd14b',bottom:'#d89400',glow:'#fff3b8'}),
 EX:Object.freeze({edge:'#ff9bc8',outer:'#f36da6',face:'#ed438a',top:'#fd6aac',bottom:'#d12a72',glow:'#ffd1e5'})
});
export const BADGE_SHORT=Object.freeze({LIGHT:'L',NORMAL:'N',HYPER:'H',EX:'EX'});
const FONT='"Arial Black", "DejaVu Sans", "Noto Sans", sans-serif';
function keyOf(chart){const raw=String(chart||'').trim().toUpperCase();const aliases={L:'LIGHT',LT:'LIGHT',N:'NORMAL',NM:'NORMAL',H:'HYPER',HP:'HYPER'};const key=aliases[raw]||raw;return Object.prototype.hasOwnProperty.call(BADGE_PALETTE,key)?key:'EX';}
function badgeText(chart,kind,value){const key=keyOf(chart);if(kind!=='level')return BADGE_SHORT[key];const num=Number(value);return Number.isInteger(num)&&num>=0&&num<=99?String(num):'–';}
// One canvas renderer is used in score lists, PSR lists, sync results and
// image sharing. Avoid SVG data-URL/inline-SVG rendering differences in Chrome.
export function officialBadgeHtml(chart,kind,value){
 const key=keyOf(chart),type=kind==='level'?'level':'chart';
 const shown=badgeText(chart,type,value);
 const label=type==='level'?`Lv.${shown}`:shown;
 return `<canvas class="official-badge-canvas" width="144" height="144" role="img" aria-label="${label}" data-badge-chart="${key}" data-badge-kind="${type}" data-badge-value="${shown}"></canvas>`;
}
export function paintOfficialBadges(root){
 if(!root)return;
 for(const canvas of root.querySelectorAll('canvas.official-badge-canvas')){
  const ctx=canvas.getContext('2d');
  if(!ctx)continue;
  ctx.clearRect(0,0,canvas.width,canvas.height);
  ctx.save();ctx.scale(canvas.width/72,canvas.height/72);
  drawOfficialBadge(ctx,canvas.dataset.badgeChart,canvas.dataset.badgeKind,canvas.dataset.badgeValue,0,0,72);
  ctx.restore();
 }
}
export function drawOfficialBadge(ctx,chart,kind,value,x,y,size){
 const key=keyOf(chart),p=BADGE_PALETTE[key],isLevel=kind==='level',shown=badgeText(chart,kind,value);
 ctx.save();ctx.translate(x,y);ctx.scale(size/72,size/72);
 function rect(a,b,w,h,r,fill,stroke,width){ctx.beginPath();ctx.roundRect(a,b,w,h,r);ctx.fillStyle=fill;ctx.fill();if(stroke){ctx.strokeStyle=stroke;ctx.lineWidth=width;ctx.stroke();}}
 rect(1.5,1.5,69,69,18.5,'#050607','#07080a',2);
 rect(4.7,4.7,62.6,62.6,15.8,p.outer,p.edge,5.4);
 rect(11,11,50,50,9.8,'#050607','#050607',4.8);
 rect(15.5,15.5,41,41,6.8,p.face,p.bottom,1.2);
 ctx.beginPath();ctx.moveTo(20,18.5);ctx.quadraticCurveTo(19,18.5,19,22);ctx.lineTo(19,27);ctx.strokeStyle=p.top;ctx.lineWidth=2;ctx.lineCap='round';ctx.globalAlpha=.6;ctx.stroke();ctx.globalAlpha=1;
 ctx.textAlign='center';ctx.textBaseline='alphabetic';ctx.lineJoin='round';ctx.fillStyle='#08080a';ctx.strokeStyle=p.glow;
 function glyph(text,y,fontSize,lineWidth,spacing){ctx.font=`1000 ${fontSize}px ${FONT}`;ctx.lineWidth=lineWidth;if(spacing&&'letterSpacing'in ctx)ctx.letterSpacing=spacing;ctx.strokeText(text,36,y);ctx.fillText(text,36,y);if(spacing&&'letterSpacing'in ctx)ctx.letterSpacing='0px';}
 if(isLevel){
  // Fixed-size typography: never fit the numeral to a height-based bounding
  // box. On Safari/Chrome actualBoundingBoxAscent varies by installed font,
  // which previously reduced two-digit levels to tiny lettering. Instead,
  // keep the official-style large numbers and constrain their width only.
  // Face is 15.5..56.5; header and number use separate fixed baselines.
  ctx.font=`900 10.5px ${FONT}`;
  ctx.lineWidth=.65;
  ctx.strokeText('Lv.',36,28,26);
  ctx.fillText('Lv.',36,28,26);
  ctx.font=`1000 29px ${FONT}`;
  ctx.lineWidth=1.05;
  ctx.strokeText(shown,36,52,34);
  ctx.fillText(shown,36,52,34);
 }

 else{
  ctx.font=`900 31px ${FONT}`;
  // EX uses the same font height as L/N/H. Only its horizontal width is fitted.
  const w=ctx.measureText(shown).width;
  if(shown==='EX'&&w>36){ctx.save();ctx.translate(36,0);ctx.scale(36/w,1);ctx.translate(-36,0);}
  glyph(shown,48,31,1.2);
  if(shown==='EX'&&w>36)ctx.restore();
 }
 ctx.restore();
}
