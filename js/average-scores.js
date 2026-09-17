// Aggregate per-chart scores from the full catalog; zero scores never contribute.
export function levelScoreAverages(rows,start,end){
  const buckets=new Map();
  for(let level=start;level<=end;level++)buckets.set(level,{level,historyTotal:0,historyCount:0,currentTotal:0,currentCount:0});
  for(const row of rows){
    const level=Number(row.level),bucket=buckets.get(level);
    if(!bucket)continue;
    // `score` is the stored all-time best, including manual and official scores.
    const history=Math.max(Number(row.score)||0,Number(row.official_score)||0,Number(row.manual_history_score)||0,Number(row.version_score)||0);
    const current=Number(row.version_score)||0;
    if(Number.isFinite(history)&&history>0){bucket.historyTotal+=history;bucket.historyCount++;}
    if(Number.isFinite(current)&&current>0){bucket.currentTotal+=current;bucket.currentCount++;}
  }
  return [...buckets.values()].reverse().map(({level,historyTotal,historyCount,currentTotal,currentCount})=>({
    level,historyCount,currentCount,
    historyAverage:historyCount?historyTotal/historyCount:null,
    currentAverage:currentCount?currentTotal/currentCount:null
  }));
}
