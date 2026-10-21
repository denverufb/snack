-- SNACK PASS DATABASE FOR SUPABASE
-- Run once in Supabase > SQL Editor > New query.
-- IMPORTANT: Auth users must be created in Supabase Auth and added to public.staff.

create table if not exists public.staff (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Staff',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.students (
  id bigint generated always as identity primary key,
  barcode text not null unique check (length(trim(barcode)) between 1 and 100),
  full_name text not null check (length(trim(full_name)) between 1 and 150),
  points integer not null default 0 check (points >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.snacks (
  id bigint generated always as identity primary key,
  barcode text not null unique check (length(trim(barcode)) between 1 and 100),
  name text not null check (length(trim(name)) between 1 and 150),
  price integer not null check (price in (1, 2)),
  stock integer check (stock is null or stock >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  kind text not null check (kind in ('purchase','reload','adjustment','refund')),
  student_id bigint not null references public.students(id),
  snack_id bigint references public.snacks(id),
  delta_points integer not null check (delta_points <> 0),
  balance_after integer not null check (balance_after >= 0),
  related_transaction_id uuid references public.transactions(id),
  note text not null default '',
  staff_id uuid not null references public.staff(id),
  created_at timestamptz not null default now()
);
create index if not exists transactions_recent_idx on public.transactions (created_at desc);
create index if not exists transactions_student_idx on public.transactions (student_id, created_at desc);
create unique index if not exists one_refund_per_purchase
  on public.transactions(related_transaction_id)
  where kind = 'refund';

-- Security: Only manually authorized staff can read data, and all writes must
-- go through checked database functions below. Never put a service-role key
-- in frontend code.
create or replace function public.is_staff()
returns boolean language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.staff where id = auth.uid() and active = true
  );
$$;

alter table public.staff enable row level security;
alter table public.students enable row level security;
alter table public.snacks enable row level security;
alter table public.transactions enable row level security;

drop policy if exists staff_self_read on public.staff;
create policy staff_self_read on public.staff for select to authenticated
  using (id = auth.uid() and public.is_staff());
drop policy if exists staff_students_read on public.students;
create policy staff_students_read on public.students for select to authenticated
  using (public.is_staff());
drop policy if exists staff_snacks_read on public.snacks;
create policy staff_snacks_read on public.snacks for select to authenticated
  using (public.is_staff());
drop policy if exists staff_transactions_read on public.transactions;
create policy staff_transactions_read on public.transactions for select to authenticated
  using (public.is_staff());

revoke all on public.staff, public.students, public.snacks, public.transactions from anon, authenticated;
grant select on public.staff, public.students, public.snacks, public.transactions to authenticated;

-- Upsert (create or reactivate) a student. Existing balance is preserved.
create or replace function public.save_student(p_barcode text, p_full_name text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.students;
begin
  if not public.is_staff() then raise exception 'Staff access required'; end if;
  p_barcode := trim(coalesce(p_barcode, ''));
  p_full_name := trim(coalesce(p_full_name, ''));
  if length(p_barcode) not between 1 and 100 or length(p_full_name) not between 1 and 150 then
    raise exception 'Provide a valid barcode and student name';
  end if;
  insert into public.students(barcode, full_name)
    values(p_barcode, p_full_name)
    on conflict(barcode) do update
      set full_name = excluded.full_name, active = true, updated_at = now()
    returning * into r;
  return to_jsonb(r);
end;
$$;

create or replace function public.set_student_active(p_barcode text, p_active boolean)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.students;
begin
  if not public.is_staff() then raise exception 'Staff access required'; end if;
  update public.students set active = p_active, updated_at = now()
    where barcode = trim(p_barcode) returning * into r;
  if not found then raise exception 'Student not found'; end if;
  return to_jsonb(r);
end;
$$;

-- NULL stock means untracked/unlimited. A value of 0 means sold out.
create or replace function public.save_snack(p_barcode text, p_name text, p_price integer, p_stock integer)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.snacks;
begin
  if not public.is_staff() then raise exception 'Staff access required'; end if;
  p_barcode := trim(coalesce(p_barcode, ''));
  p_name := trim(coalesce(p_name, ''));
  if length(p_barcode) not between 1 and 100 or length(p_name) not between 1 and 150
    or p_price not in (1, 2) or (p_stock is not null and p_stock < 0) then
    raise exception 'Check the snack barcode, name, price, and stock';
  end if;
  insert into public.snacks(barcode, name, price, stock)
    values(p_barcode, p_name, p_price, p_stock)
    on conflict(barcode) do update
      set name = excluded.name, price = excluded.price, stock = excluded.stock,
          active = true, updated_at = now()
    returning * into r;
  return to_jsonb(r);
end;
$$;

create or replace function public.set_snack_active(p_barcode text, p_active boolean)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $$
declare r public.snacks;
begin
  if not public.is_staff() then raise exception 'Staff access required'; end if;
  update public.snacks set active = p_active, updated_at = now()
    where barcode = trim(p_barcode) returning * into r;
  if not found then raise exception 'Snack not found'; end if;
  return to_jsonb(r);
end;
$$;

-- Transactional checkout. Locks rows, checks the balance, deducts points,
-- updates inventory, and writes an audit record in one atomic operation.
create or replace function public.checkout_snack(
  p_student_barcode text, p_snack_barcode text, p_request_id uuid
)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $$
declare st public.students; sn public.snacks; tx public.transactions;
begin
  if not public.is_staff() then raise exception 'Staff access required'; end if;
  if p_request_id is null then raise exception 'Missing request ID'; end if;
  select * into tx from public.transactions where request_id = p_request_id;
  if found then
    if tx.kind <> 'purchase' then raise exception 'Request ID was used for another operation'; end if;
    return jsonb_build_object('balance', tx.balance_after, 'transaction_id', tx.id, 'duplicate', true);
  end if;
  select * into st from public.students where barcode = trim(p_student_barcode) for update;
  if not found or not st.active then raise exception 'Student not found or inactive'; end if;
  select * into sn from public.snacks where barcode = trim(p_snack_barcode) for update;
  if not found or not sn.active then raise exception 'Snack not found or inactive'; end if;
  if sn.stock = 0 then raise exception 'This snack is out of stock'; end if;
  if st.points < sn.price then raise exception 'Insufficient points. Reload first.'; end if;
  update public.students set points = points - sn.price, updated_at = now()
    where id = st.id returning * into st;
  if sn.stock is not null then
    update public.snacks set stock = stock - 1, updated_at = now()
      where id = sn.id returning * into sn;
  end if;
  insert into public.transactions(request_id, kind, student_id, snack_id,
                                  delta_points, balance_after, staff_id)
    values(p_request_id, 'purchase', st.id, sn.id,
           -sn.price, st.points, auth.uid()) returning * into tx;
  return jsonb_build_object('balance', st.points, 'stock', sn.stock,
                            'transaction_id', tx.id, 'duplicate', false);
end;
$$;

-- Staff manually confirms that $5 or $10 has been received before invoking.
create or replace function public.reload_points(
  p_student_barcode text, p_points integer, p_note text, p_request_id uuid
)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $$
declare st public.students; tx public.transactions;
begin
  if not public.is_staff() then raise exception 'Staff access required'; end if;
  if p_points not in (5,10) or p_request_id is null then
    raise exception 'Reloads must be 5 or 10 points with a request ID';
  end if;
  select * into tx from public.transactions where request_id = p_request_id;
  if found then
    if tx.kind <> 'reload' then raise exception 'Request ID already used'; end if;
    return jsonb_build_object('balance', tx.balance_after, 'duplicate', true);
  end if;
  select * into st from public.students where barcode = trim(p_student_barcode) for update;
  if not found or not st.active then raise exception 'Student not found or inactive'; end if;
  update public.students set points = points + p_points, updated_at = now()
    where id = st.id returning * into st;
  insert into public.transactions(request_id, kind, student_id, delta_points,
                                  balance_after, staff_id, note)
    values(p_request_id, 'reload', st.id, p_points, st.points,
           auth.uid(), left(coalesce(p_note,''),500));
  return jsonb_build_object('balance', st.points, 'duplicate', false);
end;
$$;

-- Explicit point corrections, positive or negative, without negative balances.
create or replace function public.adjust_points(
  p_student_barcode text, p_delta integer, p_note text, p_request_id uuid
)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $$
declare st public.students; tx public.transactions;
begin
  if not public.is_staff() then raise exception 'Staff access required'; end if;
  if p_delta is null or p_delta = 0 or abs(p_delta) > 10000 or p_request_id is null then
    raise exception 'Enter a valid nonzero adjustment';
  end if;
  select * into tx from public.transactions where request_id = p_request_id;
  if found then
    if tx.kind <> 'adjustment' then raise exception 'Request ID already used'; end if;
    return jsonb_build_object('balance', tx.balance_after, 'duplicate', true);
  end if;
  select * into st from public.students where barcode = trim(p_student_barcode) for update;
  if not found then raise exception 'Student not found'; end if;
  if st.points + p_delta < 0 then raise exception 'Cannot reduce points below zero'; end if;
  update public.students set points = points + p_delta, updated_at = now()
    where id = st.id returning * into st;
  insert into public.transactions(request_id, kind, student_id, delta_points,
                                  balance_after, staff_id, note)
    values(p_request_id, 'adjustment', st.id, p_delta, st.points,
           auth.uid(), left(coalesce(p_note,''),500));
  return jsonb_build_object('balance', st.points, 'duplicate', false);
end;
$$;

-- Refund one purchase exactly once; returns points and restores tracked stock.
create or replace function public.refund_purchase(p_transaction_id uuid, p_request_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $$
declare original public.transactions; st public.students; sn public.snacks; tx public.transactions;
begin
  if not public.is_staff() then raise exception 'Staff access required'; end if;
  if p_request_id is null then raise exception 'Missing request ID'; end if;
  select * into tx from public.transactions where request_id = p_request_id;
  if found then
    if tx.kind <> 'refund' or tx.related_transaction_id <> p_transaction_id then
      raise exception 'Request ID already used';
    end if;
    return jsonb_build_object('balance', tx.balance_after, 'duplicate', true);
  end if;
  select * into original from public.transactions
    where id = p_transaction_id and kind = 'purchase';
  if not found then raise exception 'Original purchase not found'; end if;
  select * into st from public.students where id = original.student_id for update;
  if exists(select 1 from public.transactions
            where kind = 'refund' and related_transaction_id = original.id) then
    raise exception 'This purchase has already been refunded';
  end if;
  select * into sn from public.snacks where id = original.snack_id for update;
  update public.students set points = points - original.delta_points, updated_at = now()
    where id = st.id returning * into st;
  if sn.stock is not null then
    update public.snacks set stock = stock + 1, updated_at = now()
      where id = sn.id;
  end if;
  insert into public.transactions(request_id, kind, student_id, snack_id,
                                  delta_points, balance_after, related_transaction_id,
                                  staff_id, note)
    values(p_request_id, 'refund', st.id, sn.id, -original.delta_points,
           st.points, original.id, auth.uid(), 'Purchase refunded');
  return jsonb_build_object('balance', st.points, 'duplicate', false);
end;
$$;

-- Explicit function permissions. The database functions execute with their
-- owner's privileges but validate active-staff membership every time.
revoke all on function public.is_staff() from public, anon;
revoke all on function public.save_student(text,text) from public, anon;
revoke all on function public.set_student_active(text,boolean) from public, anon;
revoke all on function public.save_snack(text,text,integer,integer) from public, anon;
revoke all on function public.set_snack_active(text,boolean) from public, anon;
revoke all on function public.checkout_snack(text,text,uuid) from public, anon;
revoke all on function public.reload_points(text,integer,text,uuid) from public, anon;
revoke all on function public.adjust_points(text,integer,text,uuid) from public, anon;
revoke all on function public.refund_purchase(uuid,uuid) from public, anon;

grant execute on function public.is_staff() to authenticated;
grant execute on function public.save_student(text,text) to authenticated;
grant execute on function public.set_student_active(text,boolean) to authenticated;
grant execute on function public.save_snack(text,text,integer,integer) to authenticated;
grant execute on function public.set_snack_active(text,boolean) to authenticated;
grant execute on function public.checkout_snack(text,text,uuid) to authenticated;
grant execute on function public.reload_points(text,integer,text,uuid) to authenticated;
grant execute on function public.adjust_points(text,integer,text,uuid) to authenticated;
grant execute on function public.refund_purchase(uuid,uuid) to authenticated;

-- AFTER you add a user under Authentication > Users, run:
-- insert into public.staff (id, display_name)
-- values ('PASTE-AUTH-USER-UUID-HERE', 'Cashier');
