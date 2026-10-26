-- Run once in a disposable project. Shared by the Web, Apple and Android examples.
create table public.notes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid()
    references auth.users(id) on delete cascade,
  title text not null,
  created_at timestamptz not null default now()
);

alter table public.notes enable row level security;
grant select, insert, update, delete on public.notes to authenticated;

create policy notes_select_own on public.notes
  for select to authenticated using ((select auth.uid()) = owner_id);
create policy notes_insert_own on public.notes
  for insert to authenticated with check ((select auth.uid()) = owner_id);
create policy notes_update_own on public.notes
  for update to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);
create policy notes_delete_own on public.notes
  for delete to authenticated using ((select auth.uid()) = owner_id);
