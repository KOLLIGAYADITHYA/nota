create extension if not exists vector with schema extensions;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text,
  exam_date date,
  created_at timestamptz not null default now()
);
grant select, insert, update, delete on public.profiles to authenticated;
grant all on public.profiles to service_role;
alter table public.profiles enable row level security;
create policy "own profile select" on public.profiles for select to authenticated using (auth.uid() = id);
create policy "own profile insert" on public.profiles for insert to authenticated with check (auth.uid() = id);
create policy "own profile update" on public.profiles for update to authenticated using (auth.uid() = id);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, display_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end; $$;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

create table public.documents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid(),
  title text not null,
  page_count int not null default 0,
  chunk_count int not null default 0,
  status text not null default 'processing',
  created_at timestamptz not null default now()
);
grant select, insert, update, delete on public.documents to authenticated;
grant all on public.documents to service_role;
alter table public.documents enable row level security;
create policy "own docs" on public.documents for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

create table public.doc_chunks (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.documents(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  content text not null,
  page int not null default 1,
  chunk_index int not null default 0,
  embedding extensions.vector(1536),
  created_at timestamptz not null default now()
);
grant select, insert, update, delete on public.doc_chunks to authenticated;
grant all on public.doc_chunks to service_role;
alter table public.doc_chunks enable row level security;
create policy "own chunks" on public.doc_chunks for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create index doc_chunks_doc_idx on public.doc_chunks(document_id);
create index doc_chunks_embedding_idx on public.doc_chunks using hnsw (embedding extensions.vector_cosine_ops);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid(),
  document_id uuid references public.documents(id) on delete cascade,
  role text not null,
  content text not null,
  citations jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
grant select, insert, update, delete on public.messages to authenticated;
grant all on public.messages to service_role;
alter table public.messages enable row level security;
create policy "own messages" on public.messages for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

create table public.quizzes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid(),
  document_id uuid references public.documents(id) on delete cascade,
  title text not null,
  created_at timestamptz not null default now()
);
grant select, insert, update, delete on public.quizzes to authenticated;
grant all on public.quizzes to service_role;
alter table public.quizzes enable row level security;
create policy "own quizzes" on public.quizzes for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

create table public.quiz_questions (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid not null references public.quizzes(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  question text not null,
  options jsonb not null,
  correct_index int not null,
  explanation text,
  topic text,
  page int,
  position int not null default 0
);
grant select, insert, update, delete on public.quiz_questions to authenticated;
grant all on public.quiz_questions to service_role;
alter table public.quiz_questions enable row level security;
create policy "own questions" on public.quiz_questions for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

create table public.quiz_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid(),
  quiz_id uuid not null references public.quizzes(id) on delete cascade,
  question_id uuid not null references public.quiz_questions(id) on delete cascade,
  selected_index int not null,
  is_correct boolean not null,
  topic text,
  created_at timestamptz not null default now()
);
grant select, insert, update, delete on public.quiz_attempts to authenticated;
grant all on public.quiz_attempts to service_role;
alter table public.quiz_attempts enable row level security;
create policy "own attempts" on public.quiz_attempts for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

create or replace function public.match_chunks(
  query_embedding extensions.vector(1536),
  match_count int default 8,
  doc_id uuid default null
)
returns table (id uuid, document_id uuid, content text, page int, similarity float)
language sql stable security invoker set search_path = public, extensions as $$
  select c.id, c.document_id, c.content, c.page,
         1 - (c.embedding <=> query_embedding) as similarity
  from public.doc_chunks c
  where c.embedding is not null
    and (doc_id is null or c.document_id = doc_id)
  order by c.embedding <=> query_embedding
  limit match_count;
$$;
grant execute on function public.match_chunks(extensions.vector, int, uuid) to authenticated;