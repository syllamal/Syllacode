-- =====================================================================
-- SYLLALA KABILA : base de données partagée (Supabase)
-- À coller dans : Supabase > SQL Editor > New query > Run
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Tables ----------
create table if not exists groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text unique not null default upper(substr(encode(gen_random_bytes(4), 'hex'), 1, 8)),
  owner uuid not null references auth.users(id) on delete cascade,
  monthly int not null default 500,
  currency text not null default 'F',
  created_at timestamptz not null default now()
);

create table if not exists group_members (
  group_id uuid not null references groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member',
  primary key (group_id, user_id)
);

create table if not exists members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references groups(id) on delete cascade,
  name text not null,
  phone text default '',
  created_at timestamptz not null default now()
);

create table if not exists payments (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references groups(id) on delete cascade,
  member_id uuid references members(id) on delete set null,
  member_name text not null,
  type text not null default 'autre',
  amount int not null check (amount > 0),
  date date not null default current_date,
  note text default '',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists expenses (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references groups(id) on delete cascade,
  description text not null,
  category text not null default 'Général',
  amount int not null check (amount > 0),
  date date not null default current_date,
  created_at timestamptz not null default now()
);

create table if not exists meetings (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references groups(id) on delete cascade,
  title text not null,
  starts_at timestamptz not null,
  lieu text not null,
  details text default '',
  created_at timestamptz not null default now()
);

create table if not exists caisse (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references groups(id) on delete cascade,
  amount int not null check (amount > 0),
  date date not null default current_date,
  note text default '',
  created_at timestamptz not null default now()
);

-- ---------- Fonction d'appartenance (évite la récursion des règles) ----------
create or replace function is_member(gid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from group_members where group_id = gid and user_id = auth.uid());
$$;

-- ---------- Création d'une famille (le créateur devient propriétaire) ----------
create or replace function create_group(gname text, gmonthly int, gcurrency text)
returns uuid language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  insert into groups (name, owner, monthly, currency)
  values (gname, auth.uid(), gmonthly, gcurrency) returning id into gid;
  insert into group_members (group_id, user_id, role) values (gid, auth.uid(), 'owner');
  return gid;
end $$;

-- ---------- Rejoindre une famille avec son code ----------
create or replace function join_group(join_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  select id into gid from groups where code = upper(trim(join_code));
  if gid is null then raise exception 'Code invalide'; end if;
  insert into group_members (group_id, user_id, role) values (gid, auth.uid(), 'member')
  on conflict do nothing;
  return gid;
end $$;

-- ---------- Sécurité : chacun ne voit que ses familles ----------
alter table groups enable row level security;
alter table group_members enable row level security;
alter table members enable row level security;
alter table payments enable row level security;
alter table expenses enable row level security;
alter table meetings enable row level security;
alter table caisse enable row level security;

create policy "groups_select" on groups for select using (is_member(id) or owner = auth.uid());
create policy "groups_update_owner" on groups for update using (owner = auth.uid()) with check (owner = auth.uid());
create policy "groups_delete_owner" on groups for delete using (owner = auth.uid());

create policy "gm_select" on group_members for select using (user_id = auth.uid() or is_member(group_id));
create policy "gm_leave" on group_members for delete using (user_id = auth.uid());

create policy "members_all" on members for all using (is_member(group_id)) with check (is_member(group_id));
create policy "payments_all" on payments for all using (is_member(group_id)) with check (is_member(group_id));
create policy "expenses_all" on expenses for all using (is_member(group_id)) with check (is_member(group_id));
create policy "meetings_all" on meetings for all using (is_member(group_id)) with check (is_member(group_id));
create policy "caisse_all" on caisse for all using (is_member(group_id)) with check (is_member(group_id));

-- ---------- Synchronisation en temps réel entre les téléphones ----------
alter publication supabase_realtime add table members, payments, expenses, meetings, caisse;
alter table members replica identity full;
alter table payments replica identity full;
alter table expenses replica identity full;
alter table meetings replica identity full;
alter table caisse replica identity full;
