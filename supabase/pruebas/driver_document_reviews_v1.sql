begin;
create table private.driver_document_reviews_v1 (
 id uuid primary key default gen_random_uuid(),
 driver_id uuid not null references public.profiles(id),
 document_type text not null check(document_type in ('portrait','license','vehicle','registration','mobility_permit')),
 object_path text not null unique,
 review_state text not null default 'pending' check(review_state in ('pending','in_review','approved','rejected')),
 expires_on date,
 review_note text,
 reviewed_by uuid references public.profiles(id),
 reviewed_at timestamptz,
 created_at timestamptz not null default now(),
 check(split_part(object_path,'/',1)=driver_id::text),
 check(split_part(object_path,'/',2)=document_type)
);
alter table private.driver_document_reviews_v1 enable row level security;
revoke all on private.driver_document_reviews_v1 from public,anon,authenticated;
create index driver_document_reviews_owner_idx on private.driver_document_reviews_v1(driver_id,document_type,created_at desc);
commit;