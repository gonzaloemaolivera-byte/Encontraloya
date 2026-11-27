-- Fotos de productos: lectura publica y carga limitada al propietario del comercio.
alter table public.productos add column if not exists imagen_url text;

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('productos','productos',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=excluded.public,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "Comercios propietarios suben fotos de sus productos" on storage.objects;
create policy "Comercios propietarios suben fotos de sus productos"
on storage.objects for insert to authenticated
with check (
 bucket_id='productos'
 and exists (
   select 1 from public.comercios c
   where c.id::text=(storage.foldername(name))[1]
     and c.propietario_id=(select auth.uid())
 )
);

create or replace function public.actualizar_imagen_publicacion(p_publicacion_id uuid,p_imagen_url text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_uid uuid:=auth.uid(); v_comercio_id uuid; v_prefix text;
begin
 if v_uid is null then return pg_catalog.jsonb_build_object('ok',false,'mensaje','Iniciá sesión para guardar la foto.'); end if;
 select p.comercio_id into v_comercio_id
 from public.productos p join public.comercios c on c.id=p.comercio_id
 where p.id=p_publicacion_id and c.propietario_id=v_uid;
 if v_comercio_id is null then return pg_catalog.jsonb_build_object('ok',false,'mensaje','No encontramos esa publicación en tu comercio.'); end if;
 v_prefix:='https://egvchkzktjaitskcqlnr.supabase.co/storage/v1/object/public/productos/'||v_comercio_id::text||'/'||p_publicacion_id::text||'/';
 if p_imagen_url is not null and (pg_catalog.left(p_imagen_url,pg_catalog.length(v_prefix))<>v_prefix or pg_catalog.length(p_imagen_url)>1000) then
   return pg_catalog.jsonb_build_object('ok',false,'mensaje','La dirección de la imagen no es válida para esta publicación.');
 end if;
 update public.productos set imagen_url=p_imagen_url where id=p_publicacion_id and comercio_id=v_comercio_id;
 return pg_catalog.jsonb_build_object('ok',true,'mensaje','Foto guardada.');
end;
$$;
revoke all on function public.actualizar_imagen_publicacion(uuid,text) from public,anon;
grant execute on function public.actualizar_imagen_publicacion(uuid,text) to authenticated;
