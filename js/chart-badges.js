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
function keyOf(chart){const key=String(chart||'').toUpperCase();return Object.prototype.hasOwnProperty.call(BADGE_PALETTE,key)?key:'EX';}
function badgeText(chart,kind,value){const key=keyOf(chart);if(kind!=='level')return BADGE_SHORT[key];const num=Number(value);return Number.isInteger(num)&&num>=0&&num<=99?String(num):'–';}
// Deliberately no SVG gradient IDs: multiple badges in one document must not
// accidentally reuse another element's gradient definition.
export function officialBadgeSvg(chart,kind,value){
 const key=keyOf(chart),p=BADGE_PALETTE[key],isLevel=kind==='level',valueText=badgeText(chart,kind,value);
 const glyph=isLevel
  ? `<text x="36" y="27" font-family='${FONT}' font-size="14.5" font-weight="1000" text-anchor="middle" stroke="${p.glow}" stroke-width="0.6" paint-order="stroke fill" fill="#0b0a0c">Lv.</text><text x="36" y="56" font-family='${FONT}' font-size="30" font-weight="1000" text-anchor="middle" stroke="${p.glow}" stroke-width="1.35" stroke-linejoin="round" paint-order="stroke fill" fill="#08080a">${valueText}</text>`
  : `<text x="36" y="48.5" font-family='${FONT}' font-size="${valueText==='EX'?26:37}" font-weight="1000" letter-spacing="${valueText==='EX'?-1:0}" text-anchor="middle" stroke="${p.glow}" stroke-width="${valueText==='EX'?1.2:1.35}" stroke-linejoin="round" paint-order="stroke fill" fill="#08080a">${valueText}</text>`;
 return `<svg class="official-badge-svg" viewBox="0 0 72 72" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="${isLevel?'Lv.'+valueText:key}"><rect x="1.5" y="1.5" width="69" height="69" rx="18.5" fill="#050607" stroke="#07080a" stroke-width="2"/><rect x="4.7" y="4.7" width="62.6" height="62.6" rx="15.8" fill="${p.outer}" stroke="${p.edge}" stroke-width="5.4"/><rect x="11" y="11" width="50" height="50" rx="9.8" fill="#050607" stroke="#050607" stroke-width="4.8"/><rect x="15.5" y="15.5" width="41" height="41" rx="6.8" fill="${p.face}" stroke="${p.bottom}" stroke-width="1.2"/><path d="M20 18.5 Q19 18.5 19 22 V27" fill="none" stroke="${p.top}" stroke-width="2" opacity=".6" stroke-linecap="round"/>${glyph}</svg>`;
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
 if(isLevel){glyph('Lv.',27,14.5,.6);glyph(shown,56,30,1.35);}else glyph(shown,48.5,shown==='EX'?26:37,shown==='EX'?1.2:1.35,shown==='EX'?'-1px':null);
 ctx.restore();
}
