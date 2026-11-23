// Single visual source for LIGHT / NORMAL / HYPER / EX badges.
// Database chart identifiers and score calculations are intentionally unchanged.
export const BADGE_PALETTE=Object.freeze({
 LIGHT:{base:"#248ed5",edge:"#91d8ff",light:"#60bded",dark:"#0876b9"},
 NORMAL:{base:"#1dac4a",edge:"#9af3a0",light:"#6fe488",dark:"#07872d"},
 HYPER:{base:"#e7ad0e",edge:"#ffe782",light:"#ffe15a",dark:"#cb8600"},
 EX:{base:"#e84691",edge:"#ffa2d1",light:"#ff87b9",dark:"#c82b71"}
});
export const BADGE_SHORT=Object.freeze({LIGHT:"L",NORMAL:"N",HYPER:"H",EX:"EX"});
const FONT='Arial, "Helvetica Neue", sans-serif';
const supportedChart=chart=>Object.hasOwn(BADGE_PALETTE,String(chart||"").toUpperCase())?String(chart).toUpperCase():"EX";
export function officialBadgeSvg(chart,kind,value){
 const key=supportedChart(chart),p=BADGE_PALETTE[key],isLevel=kind==="level",number=Number(value);
 const shown=isLevel?(Number.isInteger(number)&&number>=0&&number<=99?String(number):"–"):BADGE_SHORT[key];
 const glyph=isLevel
  ?`<text x="36" y="30" font-family="Arial,sans-serif" font-size="16" font-weight="900" text-anchor="middle" fill="#090c10">Lv.</text><text x="36" y="54" font-family="Arial,sans-serif" font-size="29" font-weight="900" text-anchor="middle" fill="#080b0d">${shown}</text>`
  :`<text x="36" y="48" font-family="Arial,sans-serif" font-size="${shown==='EX'?26:37}" font-weight="900" text-anchor="middle" fill="#080b0d">${shown}</text>`;
 return `<svg class="official-badge-svg" viewBox="0 0 72 72" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="${isLevel?'Lv.'+shown:key}"><defs><linearGradient id="badge-fill-${key}" x1="0" y1="0" x2="0.8" y2="1"><stop offset="0" stop-color="${p.light}"/><stop offset=".45" stop-color="${p.base}"/><stop offset="1" stop-color="${p.dark}"/></linearGradient></defs><rect x="3.5" y="3.5" width="65" height="65" rx="17" fill="#080a0c" stroke="${p.edge}" stroke-width="5"/><rect x="10.5" y="10.5" width="51" height="51" rx="11" fill="url(#badge-fill-${key})" stroke="#080a0c" stroke-width="5"/><path d="M15 21 Q15 15 23 15 H49" fill="none" stroke="${p.light}" stroke-width="2" opacity=".57" stroke-linecap="round"/>${glyph}</svg>`;
}
// Canvas rendering uses the same geometry and palette as the SVG badge above.
export function drawOfficialBadge(ctx,chart,kind,value,x,y,size){
 const key=supportedChart(chart),p=BADGE_PALETTE[key],isLevel=kind==="level",number=Number(value),shown=isLevel?(Number.isInteger(number)&&number>=0&&number<=99?String(number):"–"):BADGE_SHORT[key];
 ctx.save();ctx.translate(x,y);ctx.scale(size/72,size/72);
 const shape=(a,b,w,h,r,fill,stroke,lw)=>{ctx.beginPath();ctx.roundRect(a,b,w,h,r);ctx.fillStyle=fill;ctx.fill();ctx.lineWidth=lw;ctx.strokeStyle=stroke;ctx.stroke();};
 shape(3.5,3.5,65,65,17,"#080a0c",p.edge,5);
 const g=ctx.createLinearGradient(12,12,58,61);g.addColorStop(0,p.light);g.addColorStop(.45,p.base);g.addColorStop(1,p.dark);
 shape(10.5,10.5,51,51,11,g,"#080a0c",5);
 ctx.beginPath();ctx.moveTo(15,21);ctx.quadraticCurveTo(15,15,23,15);ctx.lineTo(49,15);ctx.strokeStyle=p.light;ctx.globalAlpha=.57;ctx.lineWidth=2;ctx.lineCap="round";ctx.stroke();ctx.globalAlpha=1;
 ctx.textAlign="center";ctx.textBaseline="alphabetic";ctx.fillStyle="#080b0d";
 if(isLevel){ctx.font=`900 16px ${FONT}`;ctx.fillText("Lv.",36,30);ctx.font=`900 29px ${FONT}`;ctx.fillText(shown,36,54);}
 else{ctx.font=`900 ${shown==='EX'?26:37}px ${FONT}`;ctx.fillText(shown,36,48);}
 ctx.restore();
}
