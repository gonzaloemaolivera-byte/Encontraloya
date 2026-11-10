import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info, x-signature, x-request-id","Access-Control-Allow-Methods":"POST, OPTIONS","Content-Type":"application/json; charset=utf-8","Cache-Control":"no-store"};
const env=(name:string)=>{const value=Deno.env.get(name);if(!value)throw new Error("Missing "+name);return value;};
const fromB64=(s:string)=>{const v=s.replace(/-/g,"+").replace(/_/g,"/");return Uint8Array.from(atob(v+"=".repeat((4-v.length%4)%4)),c=>c.charCodeAt(0));};
async function decrypt(value:string){const [n,c]=value.split(".");const raw=fromB64(env("MP_TOKEN_ENCRYPTION_KEY"));const key=await crypto.subtle.importKey("raw",raw,"AES-GCM",false,["decrypt"]);const plain=await crypto.subtle.decrypt({name:"AES-GCM",iv:fromB64(n)},key,fromB64(c));return new TextDecoder().decode(plain);}
async function validSignature(req:Request,dataId:string){
 const signature=req.headers.get("x-signature")||"",requestId=req.headers.get("x-request-id")||"";
 const fields=Object.fromEntries(signature.split(",").map(p=>{const i=p.indexOf("=");return i<0?["",""]:[p.slice(0,i).trim(),p.slice(i+1).trim()]}));
 if(!fields.ts||!fields.v1||!requestId||!dataId)return false;
 const manifest=`id:${dataId};request-id:${requestId};ts:${fields.ts};`;
 const key=await crypto.subtle.importKey("raw",new TextEncoder().encode(env("MP_WEBHOOK_SECRET")),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
 const digest=new Uint8Array(await crypto.subtle.sign("HMAC",key,new TextEncoder().encode(manifest)));
 const expected=Array.from(digest).map(b=>b.toString(16).padStart(2,"0")).join("");
 if(expected.length!==fields.v1.length)return false;
 let diff=0;for(let i=0;i<expected.length;i++)diff|=expected.charCodeAt(i)^fields.v1.charCodeAt(i);
 return diff===0;
}
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return new Response("Method not allowed",{status:405,headers:cors});
 try{
  const url=new URL(req.url),body=await req.json().catch(()=>({}));
  const dataId=url.searchParams.get("data.id")||body?.data?.id?.toString()||"";
  const topic=url.searchParams.get("type")||body?.type||"";
  if(topic!=="payment")return new Response("ok",{status:200,headers:cors});
  if(!await validSignature(req,String(dataId)))return new Response("Invalid signature",{status:401,headers:cors});
  const admin=createClient(env("SUPABASE_URL"),env("SUPABASE_SERVICE_ROLE_KEY"),{auth:{persistSession:false,autoRefreshToken:false}});
  const sellerId=String(body.user_id||"");
  if(!sellerId)return new Response("Missing seller",{status:400,headers:cors});
  const {data:connection,error:connectionError}=await admin.from("conexiones_mercado_pago").select("comercio_id,estado,usuario_mercado_pago_id").eq("usuario_mercado_pago_id",sellerId).eq("estado","conectado").maybeSingle();
  if(connectionError||!connection)return new Response("Unknown seller",{status:404,headers:cors});
  const {data:tokenRow,error:tokenError}=await admin.from("mercado_pago_tokens_privado").select("access_token_enc").eq("comercio_id",connection.comercio_id).maybeSingle();
  if(tokenError||!tokenRow)return new Response("Missing seller token",{status:404,headers:cors});
  const token=await decrypt(tokenRow.access_token_enc);
  const paymentResponse=await fetch("https://api.mercadopago.com/v1/payments/"+encodeURIComponent(String(dataId)),{headers:{Authorization:"Bearer "+token}});
  const payment=await paymentResponse.json().catch(()=>({}));
  if(!paymentResponse.ok)return new Response("Payment lookup failed",{status:502,headers:cors});
  const orderId=String(payment.external_reference||"");
  if(!/^[0-9a-f-]{36}$/i.test(orderId)||String(payment.collector_id)!==sellerId||payment.currency_id!=="ARS")return new Response("Payment mismatch",{status:400,headers:cors});
  const {data:order,error:orderError}=await admin.from("pedidos").select("id,comercio_id,total").eq("id",orderId).maybeSingle();
  if(orderError||!order||order.comercio_id!==connection.comercio_id||Math.abs(Number(payment.transaction_amount)-Number(order.total))>0.01)return new Response("Order mismatch",{status:400,headers:cors});
  const stateMap:Record<string,string>={approved:"aprobado",rejected:"rechazado",cancelled:"cancelado",refunded:"reembolsado",charged_back:"en_disputa",in_process:"pendiente",pending:"pendiente"};
  const paymentState=stateMap[String(payment.status)]||"pendiente";
  const {data:commission}=await admin.from("comisiones").select("importe_comision").eq("pedido_id",orderId).maybeSingle();
  const {error:saveError}=await admin.from("pagos").upsert({
   pedido_id:orderId,medio_pago:"mercado_pago",proveedor:"mercado_pago",estado:paymentState,importe:Number(payment.transaction_amount),moneda:"ARS",referencia_externa:String(payment.id),idempotencia:"mp-order-"+orderId,
   fecha_confirmacion:payment.status==="approved"?(payment.date_approved||new Date().toISOString()):null,
   datos_operativos:{payment_id:String(payment.id),payment_status:String(payment.status),status_detail:payment.status_detail||null,payment_type_id:payment.payment_type_id||null,live_mode:Boolean(payment.live_mode),updated_at:new Date().toISOString()},
   actualizado_at:new Date().toISOString()
  },{onConflict:"idempotencia"});
  if(saveError)throw saveError;
  if(payment.status==="approved"){
   await admin.from("pedidos").update({estado:"confirmado",actualizado_at:new Date().toISOString()}).eq("id",orderId).eq("estado","pendiente");
   if(commission)await admin.from("comisiones").update({estado:"cobrada",importe_cobrado:Number(commission.importe_comision),actualizado_at:new Date().toISOString()}).eq("pedido_id",orderId);
  }else if(payment.status==="refunded"){
   await admin.from("pedidos").update({estado:"reembolsado",actualizado_at:new Date().toISOString()}).eq("id",orderId);
   await admin.from("comisiones").update({estado:"revertida",importe_cobrado:0,actualizado_at:new Date().toISOString()}).eq("pedido_id",orderId);
  }
  return new Response("ok",{status:200,headers:cors});
 }catch(error){console.error("mp-payment-webhook",error);return new Response("Webhook processing failed",{status:500,headers:cors});}
});
