import{db,requireDb}from"./supabase.js";

const USERNAME_DOMAIN="users.popn-score-manager.local";
const clean=value=>String(value||"").trim();
async function usernameToEmail(username){const bytes=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(clean(username)));const hex=[...new Uint8Array(bytes)].map(value=>value.toString(16).padStart(2,"0")).join("");return`u_${hex}@${USERNAME_DOMAIN}`;}

export async function register(username,password){const client=requireDb(),name=clean(username);if(!name||Array.from(name).length>32)throw new Error("アカウント名は1～32文字で入力してください。");const{data,error}=await client.auth.signUp({email:await usernameToEmail(name),password,options:{data:{username:name}}});if(error)throw error;return data;}
export async function login(username,password){const client=requireDb();const{data,error}=await client.auth.signInWithPassword({email:await usernameToEmail(username),password});if(error)throw error;return data;}
export async function logout(){if(!db)return;const{error}=await db.auth.signOut();if(error)throw error;}
export async function currentUser(){if(!db)return null;const{data}=await db.auth.getUser();return data.user||null;}
export async function currentUsername(user){if(!db||!user)return"";const{data}=await db.from("profiles").select("username").eq("id",user.id).maybeSingle();return String(data?.username||user.user_metadata?.username||"PLAYER");}
export function onAuthChange(callback){if(!db)return()=>{};const{data}=db.auth.onAuthStateChange(()=>callback());return()=>data.subscription.unsubscribe();}

