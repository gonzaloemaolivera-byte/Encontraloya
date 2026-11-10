import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
};

export function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

export function adminClient() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("Falta configuración privada de Supabase");
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

export async function authenticatedUser(req: Request) {
  const auth = req.headers.get("Authorization") || "";
  const jwt = auth.replace(/^Bearer\s+/i, "");
  if (!jwt) return null;
  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anon) throw new Error("Falta configuración pública de Supabase");
  const client = createClient(url, anon, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await client.auth.getUser(jwt);
  if (error || !data.user) return null;
  return data.user;
}

export function requiredEnv(name: string) {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Falta configurar ${name}`);
  return value;
}

function bytesToBase64(bytes: Uint8Array) {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

export async function sha256Hex(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, "0")).join("");
}

export function randomState() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return bytesToBase64(bytes);
}

async function encryptionKey() {
  const raw = requiredEnv("MP_TOKEN_ENCRYPTION_KEY");
  const binary = atob(raw);
  const bytes = Uint8Array.from(binary, c => c.charCodeAt(0));
  if (bytes.length !== 32) throw new Error("MP_TOKEN_ENCRYPTION_KEY debe contener 32 bytes codificados en Base64");
  return crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]);
}

export async function encryptToken(value: string) {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const key = await encryptionKey();
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, new TextEncoder().encode(value));
  return `${bytesToBase64(nonce)}.${bytesToBase64(new Uint8Array(ciphertext))}`;
}

