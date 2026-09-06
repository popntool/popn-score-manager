import{SUPABASE_URL,SUPABASE_ANON_KEY}from"./config.js";

export const isConfigured=Boolean(SUPABASE_URL&&SUPABASE_ANON_KEY&&SUPABASE_URL.startsWith("https://"));
export const db=isConfigured?window.supabase.createClient(SUPABASE_URL,SUPABASE_ANON_KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}):null;

export function requireDb(){if(!db)throw new Error("Supabaseが未設定です。");return db;}

