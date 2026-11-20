import{requireDb}from"./supabase.js";
import{popClassSelection}from"./scores.js?v=3.3.79";

// Display and persistence both use the same JavaScript selection and rating.
// Called after scores are read back from Supabase after a completed write.
export async function saveMyPsrSummary(rows,gameVersion){
 if(!gameVersion?.id)throw new Error("PSRの対象バージョンが未選択です。");
 const {total}=popClassSelection(rows);
 if(!Number.isFinite(total)||total<0)throw new Error("PSR集計値が不正です。");
 const {data,error}=await requireDb().rpc("save_my_psr_summary_v3379",{
  p_game_version_id:gameVersion.id,p_psr:total
 });
 if(error)throw new Error(`PSRの集計結果を保存できませんでした：${error.message||error}`);
 return Number(data);
}
